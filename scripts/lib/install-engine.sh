#!/usr/bin/env bash
# scripts/lib/install-engine.sh — YAML manifest → driver dispatcher.
# Usage:
#   bash install-engine.sh --manifest items.yaml [--installers-dir DIR] [--dry-run] [--platform OS] [--items=a,b,c]
#
# Lifecycle (per spec §C17):
#   for each item: check → install (if check fails) → verify (fallback check) → post → rollback (no-op if absent)
# Custom-script dispatch (`type: custom`): runs $script in a subshell with helpers sourced.
# Subshell isolation: each item runs in `(...)` so functions/vars don't leak across items.
#
# `post:` hook (CP4 A1-F-003, activated 2026-05-23):
#   Optional scalar or list of shell command snippets, runs ONLY after a
#   successful install + verify. Skipped when pre-install check decided
#   nothing needs to install (no re-trigger of post on idempotent re-runs).
#   Each snippet executes via `bash -c`; failure routes through rollback
#   (symmetric with verify failure) and engine exits 69.
#   Use cases: systemd reload, brew services restart, cache invalidation,
#   shim regeneration after a binary install.
#
# Platform filter:
#   Current platform resolved from $MESH_OS (export from setup.sh), --platform flag, or detect-os.sh.
#   Items with non-empty `platforms:` are processed ONLY if the current platform is in the list.
#   Items with empty/missing `platforms:` apply on every platform (default per spec C17).
#
# Exit codes:
#   0  — all items processed successfully
#   64 — arg error (missing/invalid flag)
#   65 — yaml-parse failure or missing sentinel (__YAML_PARSE_OK)
#   66 — no driver found for item type
#   67 — verify failed (rollback was called if present)
#   68 — post-install check failed (no verify function defined)
#   69 — post: hook failed (rollback was called if present)
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$ENGINE_DIR/log.sh"
# shellcheck disable=SC1091
. "$ENGINE_DIR/env.sh"
# shellcheck disable=SC1091
. "$ENGINE_DIR/install-state.sh"

DRY_RUN=0
MANIFEST=""
INSTALLERS_DIR="$ENGINE_DIR/installers"
PLATFORM_OVERRIDE=""
ITEMS_FILTER=""
TOPIC_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --manifest)        MANIFEST="$2"; shift 2 ;;
        --installers-dir)  INSTALLERS_DIR="$2"; shift 2 ;;
        --dry-run)         DRY_RUN=1; shift ;;
        --platform)        PLATFORM_OVERRIDE="$2"; shift 2 ;;
        --items=*)         ITEMS_FILTER="${1#--items=}"; shift ;;
        --items)           ITEMS_FILTER="$2"; shift 2 ;;
        --topic)           TOPIC_OVERRIDE="$2"; shift 2 ;;
        --help|-h)         sed -n '2,8p' "$0"; exit 0 ;;
        *)                 log_error "unknown arg: $1"; exit 64 ;;
    esac
done

# Topic name powers per-item install state markers (~/.local/state/mesh/installed/).
# Topic invocations always `cd "$HERE"` then run the engine, so $PWD's basename
# is reliable; --topic exists as an explicit override for tests and ad-hoc runs.
if [[ -n "$TOPIC_OVERRIDE" ]]; then
    TOPIC="$TOPIC_OVERRIDE"
elif [[ -n "${MESH_TOPIC:-}" ]]; then
    TOPIC="$MESH_TOPIC"
else
    TOPIC="$(basename "$PWD")"
fi

# Resolve current platform: --platform > $MESH_OS > detect-os.sh > "unknown"
if [[ -n "$PLATFORM_OVERRIDE" ]]; then
    PLATFORM="$PLATFORM_OVERRIDE"
elif [[ -n "${MESH_OS:-}" ]]; then
    PLATFORM="$MESH_OS"
elif [[ -r "$ENGINE_DIR/../../scripts/lib/detect-os.sh" ]]; then
    PLATFORM="$(bash "$ENGINE_DIR/../../scripts/lib/detect-os.sh")"
elif [[ -r "$ENGINE_DIR/detect-os.sh" ]]; then
    PLATFORM="$(bash "$ENGINE_DIR/detect-os.sh")"
else
    PLATFORM="unknown"
fi

_item_applies_to_platform() {
    # Args: $1 = item index. Returns 0 if item should run on $PLATFORM, 1 to skip.
    local idx="$1" count_var="ITEM_${1}_PLATFORMS_COUNT" count j entry
    count="${!count_var:-0}"
    [[ "$count" -gt 0 ]] || return 0   # empty platforms ⇒ run on all
    for ((j=0; j<count; j++)); do
        entry_var="ITEM_${idx}_PLATFORMS_${j}"
        entry="${!entry_var:-}"
        [[ "$entry" == "$PLATFORM" ]] && return 0
    done
    return 1
}

[[ -n "$MANIFEST" && -r "$MANIFEST" ]] || { log_error "missing or unreadable --manifest"; exit 64; }
[[ -d "$INSTALLERS_DIR" ]] || { log_error "missing installers dir: $INSTALLERS_DIR"; exit 64; }

parsed=$(bash "$ENGINE_DIR/yaml-parse.sh" < "$MANIFEST") || { log_error "yaml-parse failed for $MANIFEST"; exit 65; }
eval "$parsed"
[[ "${__YAML_PARSE_OK:-0}" == "1" ]] || { log_error "yaml-parse sentinel missing — parser bug or mutated"; exit 65; }

# Iterate over ITEM_0_*, ITEM_1_*, ...
processed=0
skipped_platform=0
i=0
while :; do
    name_var="ITEM_${i}_NAME"
    [[ -n "${!name_var:-}" ]] || break
    type_var="ITEM_${i}_TYPE"
    spec_var="ITEM_${i}_SPEC"
    check_var="ITEM_${i}_CHECK"
    name="${!name_var}"
    type="${!type_var:-}"
    spec="${!spec_var:-}"
    manifest_check="${!check_var:-}"
    [[ -n "$type" ]] || { log_error "item $name missing required 'type' field"; exit 64; }

    # Platform filter: skip items whose platforms: list excludes the current platform.
    if ! _item_applies_to_platform "$i"; then
        log_info "$name: skipping (platforms: excludes $PLATFORM)"
        skipped_platform=$((skipped_platform+1))
        i=$((i+1))
        continue
    fi

    # Items filter: --items=a,b,c limits which items from the manifest are processed.
    if [[ -n "$ITEMS_FILTER" ]]; then
        _in_items_filter=0
        IFS=',' read -ra _filter_entries <<< "$ITEMS_FILTER"
        for _fe in "${_filter_entries[@]}"; do
            [[ "$_fe" == "$name" ]] && { _in_items_filter=1; break; }
        done
        if (( _in_items_filter == 0 )); then
            i=$((i+1))
            continue
        fi
    fi

    # Resolve dispatch argument: custom items use script: field, others use spec:
    if [[ "$type" == "custom" ]]; then
        script_var="ITEM_${i}_SCRIPT"
        arg="${!script_var:-}"
        [[ -n "$arg" ]] || { log_error "item $name: type=custom missing required 'script' field"; exit 64; }
    else
        arg="$spec"
        # CP4 A2-F-002: refuse leading-dash specs for non-custom drivers.
        # Most package managers parse a leading `-` as an option flag, so
        # a malicious or malformed manifest could pass `--remove` or
        # `-rf /` through. Drivers add `--` separators where supported,
        # but defense-in-depth: reject at the dispatch layer.
        if [[ "$arg" == -* ]]; then
            log_error "item $name: spec begins with '-' which would be parsed as a CLI option by the $type driver (refused for safety)"
            exit 64
        fi
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[dry-run] would process: $name ($type) arg=$arg"
        processed=$((processed+1))
        i=$((i+1))
        continue
    fi

    (   # subshell — isolation per item (P4 validation)
        driver="$INSTALLERS_DIR/${type}.sh"
        if [[ ! -r "$driver" ]]; then
            log_error "no driver for type=$type (item: $name)"
            exit 66
        fi
        # shellcheck disable=SC1090
        . "$driver"
        prefix="${type//-/_}"   # brew-formula → brew_formula
        # Pre-install check. Manifest `check:` (if set) OVERRIDES driver _check —
        # gives authors a per-item escape hatch (e.g. `command -v rtk` to skip
        # an npx-style fresh install when the binary is already on PATH).
        # CP4 F-003: closes the silent-dead-config gap exposed in chunk F.
        if [[ -n "$manifest_check" ]]; then
            if bash -c "$manifest_check" >/dev/null 2>&1; then
                # Backfill the install marker on first sight: the package is
                # verifiably present, so adopt it as mesh-managed even though
                # we didn't run the installer. After this, the menu shows it
                # as steady-state instead of "foreign install".
                install_state_record "$TOPIC" "$name" "$type" "$arg" 2>/dev/null || true
                log_info "$name: already present (manifest check), skipping"
                exit 0
            fi
        elif "${prefix}_check" "$arg" 2>/dev/null; then
            install_state_record "$TOPIC" "$name" "$type" "$arg" 2>/dev/null || true
            log_info "$name: already present, skipping"
            exit 0
        fi
        log_info "$name: installing"
        # Capture install rc explicitly. Codex review 2026-05-19 (A-F003 / F-F005):
        # `set -euo pipefail` was exiting the subshell on install() failure
        # BEFORE rollback could fire — leaving partial state behind. The
        # `cmd || rc=$?` form both (a) suppresses `set -e` on install failure
        # and (b) captures the actual rc (`if ! cmd; then $?` zeros it).
        _install_rc=0
        "${prefix}_install" "$arg" || _install_rc=$?
        if [[ "$_install_rc" -ne 0 ]]; then
            log_warn "$name: install failed (rc=$_install_rc); calling rollback if present"
            declare -f "${prefix}_rollback" >/dev/null 2>&1 && "${prefix}_rollback" "$arg"
            exit "$_install_rc"
        fi
        # Post-install verify. Priority: driver verify > manifest check > driver check.
        # Manifest check used as verify fallback closes the contract symmetry
        # with pre-install (CP4 F-003).
        # CP4 A1-F-001: all 3 failure paths now route through rollback for
        # symmetry — previously only driver _verify failure called rollback,
        # leaving partial state for manifest-check/driver-check failures.
        _post_check_ok=0
        if declare -f "${prefix}_verify" >/dev/null 2>&1; then
            "${prefix}_verify" "$arg" && _post_check_ok=1
        elif [[ -n "$manifest_check" ]]; then
            bash -c "$manifest_check" >/dev/null 2>&1 && _post_check_ok=1
        else
            "${prefix}_check" "$arg" 2>/dev/null && _post_check_ok=1
        fi
        if (( _post_check_ok == 0 )); then
            log_warn "$name: post-install verification failed; calling rollback if present"
            declare -f "${prefix}_rollback" >/dev/null 2>&1 && "${prefix}_rollback" "$arg"
            exit 67
        fi
        # Record install marker so the menu scanner can answer "did mesh
        # install this?" without per-driver knowledge. Marker dir lives at
        # ~/.local/state/mesh/installed/ (overridable via MESH_INSTALL_STATE_DIR).
        # Soft-fails: a marker-write failure must not abort an otherwise
        # successful install.
        install_state_record "$TOPIC" "$name" "$type" "$arg" \
            || log_warn "$name: failed to record install state marker (continuing)"
        # CP4 A1-F-003: optional post: hook. Iterates over the list emitted
        # by yaml-parse (scalar post: foo → POST_COUNT=1 + POST_0=foo; list
        # form expanded into POST_<n>). Skipped silently when post_count=0.
        post_count_var="ITEM_${i}_POST_COUNT"
        post_count="${!post_count_var:-0}"
        if (( post_count > 0 )); then
            for ((p=0; p<post_count; p++)); do
                post_entry_var="ITEM_${i}_POST_${p}"
                post_cmd="${!post_entry_var:-}"
                [[ -n "$post_cmd" ]] || continue
                if ! bash -c "$post_cmd"; then
                    log_warn "$name: post[$p] failed (cmd: $post_cmd); calling rollback if present"
                    declare -f "${prefix}_rollback" >/dev/null 2>&1 && "${prefix}_rollback" "$arg"
                    exit 69
                fi
            done
            log_info "$name: post completed ($post_count command(s))"
        fi
    ) || { _rc=$?; log_error "$name: failed (rc=$_rc)"; exit $_rc; }
    processed=$((processed+1))
    i=$((i+1))
done

if (( skipped_platform > 0 )); then
    log_info "engine: completed $processed items on $PLATFORM ($skipped_platform skipped by platforms: filter)"
else
    log_info "engine: completed $processed items on $PLATFORM"
fi
