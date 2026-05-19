#!/usr/bin/env bash
# scripts/lib/install-engine.sh — YAML manifest → driver dispatcher.
# Usage:
#   bash install-engine.sh --manifest items.yaml [--installers-dir DIR] [--dry-run] [--platform OS]
#
# Lifecycle (per spec §C17):
#   for each item: check → install (if check fails) → verify (fallback check) → rollback (no-op if absent)
# Custom-script dispatch (`type: custom`): runs $script in a subshell with helpers sourced.
# Subshell isolation: each item runs in `(...)` so functions/vars don't leak across items.
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
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$ENGINE_DIR/log.sh"
# shellcheck disable=SC1091
. "$ENGINE_DIR/env.sh"

DRY_RUN=0
MANIFEST=""
INSTALLERS_DIR="$ENGINE_DIR/installers"
PLATFORM_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --manifest)        MANIFEST="$2"; shift 2 ;;
        --installers-dir)  INSTALLERS_DIR="$2"; shift 2 ;;
        --dry-run)         DRY_RUN=1; shift ;;
        --platform)        PLATFORM_OVERRIDE="$2"; shift 2 ;;
        --help|-h)         sed -n '2,8p' "$0"; exit 0 ;;
        *)                 log_error "unknown arg: $1"; exit 64 ;;
    esac
done

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
    name="${!name_var}"
    type="${!type_var:-}"
    spec="${!spec_var:-}"
    [[ -n "$type" ]] || { log_error "item $name missing required 'type' field"; exit 64; }

    # Platform filter: skip items whose platforms: list excludes the current platform.
    if ! _item_applies_to_platform "$i"; then
        log_info "$name: skipping (platforms: excludes $PLATFORM)"
        skipped_platform=$((skipped_platform+1))
        i=$((i+1))
        continue
    fi

    # Resolve dispatch argument: custom items use script: field, others use spec:
    if [[ "$type" == "custom" ]]; then
        script_var="ITEM_${i}_SCRIPT"
        arg="${!script_var:-}"
        [[ -n "$arg" ]] || { log_error "item $name: type=custom missing required 'script' field"; exit 64; }
    else
        arg="$spec"
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
        if "${prefix}_check" "$arg" 2>/dev/null; then
            log_info "$name: already present, skipping"
            exit 0
        fi
        log_info "$name: installing"
        "${prefix}_install" "$arg"
        if declare -f "${prefix}_verify" >/dev/null 2>&1; then
            "${prefix}_verify" "$arg" || {
                log_warn "$name: verify failed; calling rollback if present"
                declare -f "${prefix}_rollback" >/dev/null 2>&1 && "${prefix}_rollback" "$arg"
                exit 67
            }
        else
            "${prefix}_check" "$arg" 2>/dev/null || {
                log_warn "$name: post-install check failed"
                exit 68
            }
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
