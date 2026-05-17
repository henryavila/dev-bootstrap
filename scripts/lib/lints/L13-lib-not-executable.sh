#!/usr/bin/env bash
# L13 — files under scripts/lib/ are source-only and must not carry the
# executable bit. Runtime entrypoints live in bin/, scripts/runners/, and
# scripts/internal/ (per Phase 2 4-way split, spec §C18).
# Spec: §C21. Phase 5 Task 5.2.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

hits=$(find "$ROOT/scripts/lib" -type f -name '*.sh' -perm -u+x 2>/dev/null || true)

if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | sed "s|^$ROOT/|L13: |; s|$| (source-only; chmod -x)|"
    exit 1
fi
exit 0
