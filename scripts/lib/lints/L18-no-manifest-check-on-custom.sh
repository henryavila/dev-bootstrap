#!/usr/bin/env bash
# L18 — type:custom items must NOT define a manifest `check:` field.
#
# Engine semantics: install-engine consumes ITEM_<i>_CHECK as a manifest-level
# override that runs INSTEAD of the driver's check function. For type:custom
# items the driver dispatches to the script's `check()` function, so a
# manifest `check:` silently shadows the script's intended logic — the case
# that bit topic 82-ai-tools in CP4 A2-F-007 (rtk's collision guard was
# bypassed once A2-F-007 generalized the manifest_check override).
#
# Fix the schema, not the engine: forbid mixing the two. type:custom items
# express their check via the script (which the author owns and tests);
# non-custom items express it via the manifest field (where regex-style
# overrides are intentional). This lint catches the mixed schema at commit
# time instead of runtime.
#
# Spec: §C17 / A3-F-011.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

shopt -s nullglob
manifests=("$ROOT/topics"/*/items.yaml)
shopt -u nullglob
(( ${#manifests[@]} == 0 )) && exit 0

failed=0
for manifest in "${manifests[@]}"; do
    rel="${manifest#"$ROOT"/}"
    out=$(awk '
        /^[[:space:]]*-[[:space:]]*name:/ {
            if (in_blk && b_type == "custom" && b_check != "") {
                printf "L18: %s: item %s has both `type: custom` and manifest `check:` (engine override would shadow script check())\n", FILENAME, b_name
            }
            in_blk=1; b_type=""; b_check=""; b_name=$0
            sub(/.*name:[[:space:]]*/, "", b_name)
            gsub(/["'"'"']/, "", b_name)
            next
        }
        in_blk && /^[[:space:]]+type:[[:space:]]*custom([[:space:]]|$)/ { b_type="custom" }
        in_blk && /^[[:space:]]+check:/ { b_check=$0 }
        END {
            if (in_blk && b_type == "custom" && b_check != "") {
                printf "L18: %s: item %s has both `type: custom` and manifest `check:` (engine override would shadow script check())\n", FILENAME, b_name
            }
        }
    ' FILENAME="$rel" "$manifest")
    if [[ -n "$out" ]]; then
        printf '%s\n' "$out"
        failed=1
    fi
done

exit "$failed"
