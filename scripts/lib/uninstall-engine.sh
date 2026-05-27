#!/usr/bin/env bash
# scripts/lib/uninstall-engine.sh — YAML-driven uninstall orchestrator.
#
# Separate from install-engine.sh per spec D-B3 (engine has zero uninstall logic).
# Maps driver types from items.yaml to handlers in uninstall-handlers.sh.
# Custom scripts: sources script, calls uninstall() if defined.
#
# Usage:
#   bash uninstall-engine.sh --manifest items.yaml --items=x,y [--dry-run] [--platform OS]
#
# Exit codes:
#   0  — all items processed
#   64 — arg error
#   65 — yaml-parse failure

set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$ENGINE_DIR/log.sh"
# shellcheck disable=SC1091
. "$ENGINE_DIR/env.sh"
# shellcheck disable=SC1091
. "$ENGINE_DIR/uninstall-handlers.sh"

DRY_RUN=0
MANIFEST=""
ITEMS_FILTER=""
PLATFORM_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --manifest)    MANIFEST="$2"; shift 2 ;;
        --items=*)     ITEMS_FILTER="${1#--items=}"; shift ;;
        --items)       ITEMS_FILTER="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=1; shift ;;
        --platform)    PLATFORM_OVERRIDE="$2"; shift 2 ;;
        --help|-h)     sed -n '2,8p' "$0"; exit 0 ;;
        *)             log_error "unknown arg: $1"; exit 64 ;;
    esac
done

if [[ -n "$PLATFORM_OVERRIDE" ]]; then
    PLATFORM="$PLATFORM_OVERRIDE"
elif [[ -n "${MESH_OS:-}" ]]; then
    PLATFORM="$MESH_OS"
elif [[ -r "$ENGINE_DIR/detect-os.sh" ]]; then
    PLATFORM="$(bash "$ENGINE_DIR/detect-os.sh")"
else
    PLATFORM="unknown"
fi

_item_applies_to_platform() {
    local idx="$1" count_var="ITEM_${1}_PLATFORMS_COUNT" count j entry
    count="${!count_var:-0}"
    [[ "$count" -gt 0 ]] || return 0
    for ((j=0; j<count; j++)); do
        entry_var="ITEM_${idx}_PLATFORMS_${j}"
        entry="${!entry_var:-}"
        [[ "$entry" == "$PLATFORM" ]] && return 0
    done
    return 1
}

[[ -n "$MANIFEST" && -r "$MANIFEST" ]] || { log_error "missing or unreadable --manifest"; exit 64; }
[[ -n "$ITEMS_FILTER" ]] || { log_error "missing --items (required for uninstall)"; exit 64; }

parsed=$(bash "$ENGINE_DIR/yaml-parse.sh" < "$MANIFEST") || { log_error "yaml-parse failed"; exit 65; }
eval "$parsed"
[[ "${__YAML_PARSE_OK:-0}" == "1" ]] || { log_error "yaml-parse sentinel missing"; exit 65; }

IFS=',' read -ra FILTER_ENTRIES <<< "$ITEMS_FILTER"
_in_filter() {
    local name="$1"
    for fe in "${FILTER_ENTRIES[@]}"; do
        [[ "$fe" == "$name" ]] && return 0
    done
    return 1
}

processed=0
i=0
while :; do
    name_var="ITEM_${i}_NAME"
    [[ -n "${!name_var:-}" ]] || break
    name="${!name_var}"
    type_var="ITEM_${i}_TYPE"; type="${!type_var:-}"
    spec_var="ITEM_${i}_SPEC"; spec="${!spec_var:-}"

    if ! _in_filter "$name"; then
        i=$((i+1)); continue
    fi

    if ! _item_applies_to_platform "$i"; then
        log_info "$name: skipping uninstall (platform mismatch)"
        i=$((i+1)); continue
    fi

    if (( DRY_RUN )); then
        log_info "[dry-run] would uninstall: $name (type=$type)"
        i=$((i+1)); processed=$((processed+1)); continue
    fi

    case "$type" in
        brew-formula)  _uninstall_brew "$spec" ;;
        brew-cask)     _uninstall_brew_cask "$spec" ;;
        apt)           _uninstall_apt "$spec" ;;
        npm-global)    _uninstall_npm_global "$spec" ;;
        cargo)         _uninstall_cargo "$spec" ;;
        pip)           _uninstall_pip "$spec" ;;
        npx)           _uninstall_npx "$spec" ;;
        git-clone)     _uninstall_clone "$spec" ;;
        custom)
            script_var="ITEM_${i}_SCRIPT"
            script="${!script_var:-}"
            if [[ -n "$script" ]]; then
                local_script="$script"
                [[ "$local_script" == ./* ]] && local_script="$(dirname "$MANIFEST")/$local_script"
                if [[ -r "$local_script" ]]; then
                    (
                        # shellcheck disable=SC1090
                        source "$local_script"
                        if declare -f uninstall >/dev/null 2>&1; then
                            uninstall
                        else
                            warn "$name: no uninstall() function — remove manually"
                        fi
                    )
                else
                    warn "$name: script not found: $local_script"
                fi
            else
                warn "$name: type=custom but no script field"
            fi
            ;;
        *)
            warn "$name: no uninstall handler for type=$type"
            ;;
    esac

    processed=$((processed+1))
    i=$((i+1))
done

log_info "uninstall-engine: processed $processed items"
