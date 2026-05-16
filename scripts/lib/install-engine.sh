#!/usr/bin/env bash
# scripts/lib/install-engine.sh — YAML manifest → driver dispatcher.
# Usage:
#   bash install-engine.sh --manifest items.yaml [--installers-dir DIR] [--dry-run]
#
# Lifecycle (per spec §C17):
#   for each item: check → install (if check fails) → verify (fallback check) → rollback (no-op if absent)
# Custom-script dispatch (`type: custom`): runs $script in a subshell with helpers sourced.
# Subshell isolation: each item runs in `(...)` so functions/vars don't leak across items.
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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --manifest)        MANIFEST="$2"; shift 2 ;;
        --installers-dir)  INSTALLERS_DIR="$2"; shift 2 ;;
        --dry-run)         DRY_RUN=1; shift ;;
        --help|-h)         sed -n '2,8p' "$0"; exit 0 ;;
        *)                 log_error "unknown arg: $1"; exit 64 ;;
    esac
done

[[ -n "$MANIFEST" && -r "$MANIFEST" ]] || { log_error "missing or unreadable --manifest"; exit 64; }
[[ -d "$INSTALLERS_DIR" ]] || { log_error "missing installers dir: $INSTALLERS_DIR"; exit 64; }

parsed=$(bash "$ENGINE_DIR/yaml-parse.sh" < "$MANIFEST") || { log_error "yaml-parse failed for $MANIFEST"; exit 65; }
eval "$parsed"
[[ "${__YAML_PARSE_OK:-0}" == "1" ]] || { log_error "yaml-parse sentinel missing — parser bug or mutated"; exit 65; }

# Iterate over ITEM_0_*, ITEM_1_*, ...
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

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[dry-run] would process: $name ($type) spec=$spec"
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
        if "${prefix}_check" "$spec" 2>/dev/null; then
            log_info "$name: already present, skipping"
            exit 0
        fi
        log_info "$name: installing"
        "${prefix}_install" "$spec"
        if declare -f "${prefix}_verify" >/dev/null 2>&1; then
            "${prefix}_verify" "$spec" || {
                log_warn "$name: verify failed; calling rollback if present"
                declare -f "${prefix}_rollback" >/dev/null 2>&1 && "${prefix}_rollback" "$spec"
                exit 67
            }
        else
            "${prefix}_check" "$spec" 2>/dev/null || {
                log_warn "$name: post-install check failed"
                exit 68
            }
        fi
        # TODO(Task 1.7/82-ai-tools): type:custom must pass ITEM_N_SCRIPT not $spec; yaml-parse emits it.
    ) || { _rc=$?; log_error "$name: failed (rc=$_rc)"; exit $_rc; }
    i=$((i+1))
done

log_info "engine: completed $i items"
