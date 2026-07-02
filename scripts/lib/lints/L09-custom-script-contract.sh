#!/usr/bin/env bash
# L09 — custom-script lifecycle contract.
#
# A `type: custom` item is sourced by scripts/lib/installers/custom.sh, so the
# script must declare the lifecycle functions the engine depends on. Hard
# contract:
#   - check()   : pre-install keep/skip probe
#   - install() : install action
#   - verify()  : post-install/doctor strong probe
#   - repair()  : doctor --fix action for non-idempotent custom items
#
# Idempotent custom items are deliberately exempt from repair(): the repair
# sweep already re-applies idempotent items through update/apply paths and
# install-engine.sh skips custom_repair for them.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
PARSER="$ROOT/scripts/lib/yaml-parse.sh"

fn_defined() {
    local file="$1" fn="$2"
    grep -Eq "^[[:space:]]*(${fn}[[:space:]]*\\(\\)|function[[:space:]]+${fn}([[:space:]]*\\(\\))?)[[:space:]]*\\{" "$file"
}

check_script_contract() {
    local script_abs="$1" origin="$2" idempotent="$3"
    local rel fn failed=0
    rel="${script_abs#"$ROOT"/}"

    if [[ ! -f "$script_abs" ]]; then
        printf 'L09: %s: custom script not found at %s\n' "$origin" "$rel"
        return 1
    fi

    for fn in check install verify; do
        if ! fn_defined "$script_abs" "$fn"; then
            printf 'L09: %s: missing function %s()\n' "$rel" "$fn"
            failed=1
        fi
    done

    if [[ "$idempotent" != 1 ]] && ! fn_defined "$script_abs" repair; then
        printf 'L09: %s: missing function repair() for non-idempotent custom item\n' "$rel"
        failed=1
    fi

    return "$failed"
}

failed=0

shopt -s nullglob
manifests=("$ROOT"/topics/*/manifest.yaml)
shopt -u nullglob

for manifest in "${manifests[@]}"; do
    manifest_dir="$(dirname "$manifest")"
    rel_manifest="${manifest#"$ROOT"/}"
    parsed="$(MESH_YAML_META=1 "$PARSER" < "$manifest" 2>/dev/null)"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        printf 'L09: %s: yaml-parse.sh rejected manifest; cannot validate custom contracts\n' "$rel_manifest"
        failed=1
        continue
    fi

    tmp="$(mktemp "${TMPDIR:-/tmp}/mesh-l09.XXXXXX")"
    (
        eval "$parsed"
        if [[ "${__YAML_PARSE_OK:-0}" != 1 ]]; then
            printf 'L09: %s: yaml-parse.sh output missing sentinel\n' "$rel_manifest"
            exit 1
        fi

        local_failed=0
        b=0
        while [[ "$b" -lt "${BUNDLE_COUNT:-0}" ]]; do
            eval "bundle_name=\${BUNDLE_${b}_NAME:-bundle-$b}"
            eval "item_count=\${BUNDLE_${b}_ITEM_COUNT:-0}"
            i=0
            while [[ "$i" -lt "$item_count" ]]; do
                eval "item_name=\${BUNDLE_${b}_ITEM_${i}_NAME:-item-$i}"
                eval "item_type=\${BUNDLE_${b}_ITEM_${i}_TYPE:-}"
                eval "item_script=\${BUNDLE_${b}_ITEM_${i}_SCRIPT:-}"
                eval "item_idempotent=\${BUNDLE_${b}_ITEM_${i}_IDEMPOTENT:-0}"
                if [[ "$item_type" = custom ]]; then
                    if [[ -z "$item_script" ]]; then
                        printf 'L09: %s: bundle %s item %s missing script\n' \
                            "$rel_manifest" "$bundle_name" "$item_name"
                        local_failed=1
                    else
                        case "$item_script" in
                            /*) script_abs="$item_script" ;;
                            *)  script_abs="$manifest_dir/${item_script#./}" ;;
                        esac
                        origin="$rel_manifest: bundle $bundle_name item $item_name"
                        check_script_contract "$script_abs" "$origin" "$item_idempotent" || local_failed=1
                    fi
                fi
                i=$((i + 1))
            done
            b=$((b + 1))
        done
        exit "$local_failed"
    ) > "$tmp"
    rc=$?
    if [[ -s "$tmp" ]]; then
        cat "$tmp"
    fi
    rm -f "$tmp"
    [[ $rc -eq 0 ]] || failed=1
done

exit "$failed"
