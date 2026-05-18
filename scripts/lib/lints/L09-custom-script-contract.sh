#!/usr/bin/env bash
# L09 — custom-script files must define check/install/verify/rollback. A
# "custom-script" is a file referenced by a `type: custom` entry in any
# topics/*/items.yaml (the engine's escape-hatch path). Engine sources the
# script in a subshell and dispatches the 4 lifecycle hooks; missing any
# function is a runtime breakage.
#
# Resolution: each items.yaml block `type: custom` is paired with a `script:`
# field holding a path relative to the items.yaml directory.
#
# Spec: §C21 / D-B1 / L9 belt-and-suspenders. Phase 5 emerged item.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

shopt -s nullglob
manifests=("$ROOT/topics"/*/items.yaml)
shopt -u nullglob
(( ${#manifests[@]} == 0 )) && exit 0

required=(check install verify rollback)
failed=0

# Lightweight YAML parser: pair `type: custom` with the matching `script:` in
# the same `- name:` block. Emit one script path per line.
_extract_custom_scripts() {
    awk '
        /^[[:space:]]*-[[:space:]]*name:/ {
            if (in_block && block_type == "custom" && block_script != "") {
                print block_script
            }
            in_block=1; block_type=""; block_script=""; next
        }
        in_block && /^[[:space:]]+type:[[:space:]]*custom/ { block_type="custom" }
        in_block && /^[[:space:]]+script:/ {
            v = $0
            sub(/^[[:space:]]+script:[[:space:]]*/, "", v)
            gsub(/["'"'"']/, "", v)
            block_script = v
        }
        END {
            if (in_block && block_type == "custom" && block_script != "") {
                print block_script
            }
        }
    ' "$1"
}

for manifest in "${manifests[@]}"; do
    manifest_dir="$(dirname "$manifest")"
    while IFS= read -r script_rel; do
        [[ -n "$script_rel" ]] || continue
        case "$script_rel" in
            /*)  script_abs="$script_rel" ;;
            *)   script_abs="$manifest_dir/${script_rel#./}" ;;
        esac
        if [[ ! -f "$script_abs" ]]; then
            printf 'L09: %s: custom script not found at %s\n' \
                "${manifest#"$ROOT"/}" "${script_abs#"$ROOT"/}"
            failed=1
            continue
        fi
        for fn in "${required[@]}"; do
            if ! grep -qE "^${fn}\(\)[[:space:]]*\{?" "$script_abs"; then
                printf 'L09: %s: missing function %s()\n' \
                    "${script_abs#"$ROOT"/}" "$fn"
                failed=1
            fi
        done
    done < <(_extract_custom_scripts "$manifest")
done

exit "$failed"
