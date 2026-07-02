#!/usr/bin/env bash
# L19 — installer drivers must satisfy the engine lifecycle contract.
#
# install-engine.sh dispatches installer types through scripts/lib/installers:
#   <type>_check, <type>_install, <type>_verify, <type>_repair
#
# This lint fails closed in two directions:
#   - every shipped driver file must declare the four lifecycle functions;
#   - every non-custom manifest item type must have a matching shipped driver.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
PARSER="$ROOT/scripts/lib/yaml-parse.sh"
DRIVERS_DIR="$ROOT/scripts/lib/installers"

fn_defined() {
    local file="$1" fn="$2"
    grep -Eq "^[[:space:]]*(${fn}[[:space:]]*\\(\\)|function[[:space:]]+${fn}([[:space:]]*\\(\\))?)[[:space:]]*\\{" "$file"
}

driver_prefix() {
    printf '%s' "$1" | tr '-' '_'
}

failed=0

shopt -s nullglob
drivers=("$DRIVERS_DIR"/*.sh)
shopt -u nullglob

for driver in "${drivers[@]}"; do
    type="$(basename "$driver" .sh)"
    prefix="$(driver_prefix "$type")"
    for verb in check install verify repair; do
        fn="${prefix}_${verb}"
        if ! fn_defined "$driver" "$fn"; then
            printf 'L19: %s: missing function %s()\n' "${driver#"$ROOT"/}" "$fn"
            failed=1
        fi
    done
done

shopt -s nullglob
manifests=("$ROOT"/topics/*/manifest.yaml)
shopt -u nullglob

for manifest in "${manifests[@]}"; do
    rel_manifest="${manifest#"$ROOT"/}"
    parsed="$(MESH_YAML_META=1 "$PARSER" < "$manifest" 2>/dev/null)"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        printf 'L19: %s: yaml-parse.sh rejected manifest; cannot validate item driver types\n' "$rel_manifest"
        failed=1
        continue
    fi

    tmp="$(mktemp "${TMPDIR:-/tmp}/mesh-l19.XXXXXX")"
    (
        eval "$parsed"
        if [[ "${__YAML_PARSE_OK:-0}" != 1 ]]; then
            printf 'L19: %s: yaml-parse.sh output missing sentinel\n' "$rel_manifest"
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
                if [[ -n "$item_type" && "$item_type" != custom ]]; then
                    driver="$DRIVERS_DIR/$item_type.sh"
                    if [[ ! -f "$driver" ]]; then
                        printf 'L19: %s: bundle %s item %s uses unknown driver type `%s`\n' \
                            "$rel_manifest" "$bundle_name" "$item_name" "$item_type"
                        local_failed=1
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
