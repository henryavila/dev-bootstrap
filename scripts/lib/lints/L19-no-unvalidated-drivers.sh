#!/usr/bin/env bash
# L19 — block items.yaml entries using drivers with known contract gaps.
#
# Drivers git-clone, go-install, and github-release have 0 active callers
# and known bugs (CP4 A2-F-004/F-005/F-006). Until each driver's contract
# is validated and fixed, this lint prevents silent adoption of broken
# install/check/verify semantics.
#
# When a driver is fixed, remove it from the BLOCKED list below.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

BLOCKED="git-clone|go-install|github-release"

shopt -s nullglob
manifests=("$ROOT/topics"/*/items.yaml)
shopt -u nullglob
(( ${#manifests[@]} == 0 )) && exit 0

failed=0
for manifest in "${manifests[@]}"; do
    rel="${manifest#"$ROOT"/}"
    out=$(awk -v blocked="$BLOCKED" '
        BEGIN { split(blocked, arr, "|"); for (i in arr) bad[arr[i]]=1 }
        /^[[:space:]]*-[[:space:]]*name:/ {
            if (in_blk && b_type in bad) {
                printf "L19: %s: item %s uses unvalidated driver `type: %s` — fix driver contract (CP4 A2-F-004/F-005/F-006) before use\n", FILENAME, b_name, b_type
            }
            in_blk=1; b_type=""; b_name=$0
            sub(/.*name:[[:space:]]*/, "", b_name)
            gsub(/["'"'"']/, "", b_name)
            next
        }
        in_blk && /^[[:space:]]+type:[[:space:]]*/ {
            b_type=$0
            sub(/.*type:[[:space:]]*/, "", b_type)
            gsub(/[[:space:]].*/, "", b_type)
            gsub(/["'"'"']/, "", b_type)
        }
        END {
            if (in_blk && b_type in bad) {
                printf "L19: %s: item %s uses unvalidated driver `type: %s` — fix driver contract (CP4 A2-F-004/F-005/F-006) before use\n", FILENAME, b_name, b_type
            }
        }
    ' FILENAME="$rel" "$manifest")
    if [[ -n "$out" ]]; then
        printf '%s\n' "$out"
        failed=1
    fi
done

exit "$failed"
