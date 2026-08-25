#!/usr/bin/env bash
# L13 — files under scripts/lib/ are source-only and must not carry the
# executable bit. Runtime entrypoints live in bin/, scripts/runners/, and
# scripts/internal/ (per Phase 2 4-way split, spec §C18).
#
# Exceptions (allowlist):
#   - yaml-parse.sh  dual-mode standalone parser. Its docstring + the
#                    parser test invoke it directly (`"$PARSER" < input`),
#                    so it legitimately needs +x.
#
# Spec: §C21. Phase 5 Task 5.2.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

# Prefer git index modes: WSL /mnt/<drive> (drvfs) reports every file as
# executable, so `find -perm -u+x` false-positives the whole tree.
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    hits=$(git -C "$ROOT" ls-files -s -- scripts/lib \
        | awk '$1 == "100755" { print $4 }' \
        | grep '\.sh$' \
        | grep -vE '(^|/)yaml-parse\.sh$' || true)
else
    hits=$(find "$ROOT/scripts/lib" -type f -name '*.sh' -perm -u+x 2>/dev/null \
        | grep -vE '/(yaml-parse)\.sh$' || true)
fi

if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | sed "s|^$ROOT/||; s|^|L13: |; s|$| (source-only; chmod -x)|"
    exit 1
fi
exit 0
