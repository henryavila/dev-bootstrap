#!/usr/bin/env bash
# L11 — every file under template/ ends in `.example` (C16 parity rule). The
# template/ dir is materialized in Phase 6; until then, this lint is a no-op.
# Spec: §C21. Phase 5 Task 5.2.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
TPL="$ROOT/template"

[[ -d "$TPL" ]] || exit 0

hits=$(find "$TPL" -type f \
    -not -name '*.example' \
    -not -name '.keep' \
    -not -iname 'README*' \
    2>/dev/null || true)

if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | sed "s|^$ROOT/|L11: |; s|$| (must end in .example per C16)|"
    exit 1
fi
exit 0
