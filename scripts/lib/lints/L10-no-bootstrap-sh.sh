#!/usr/bin/env bash
# L10 — no `bootstrap.sh` references in code (post Phase 2 rename to setup.sh).
# Comments and docs are exempt (they may reference history). Tests excluded.
# Spec: §C21. Phase 5 Task 5.2.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

hits=$(grep -rnE '^[^#]*\bbootstrap\.sh\b' \
    --include='*.sh' --include='*.zsh' \
    --exclude-dir=tests --exclude-dir=.git --exclude-dir=docs --exclude-dir=archive \
    "$ROOT/scripts" "$ROOT/topics" "$ROOT/bin" 2>/dev/null || true)

if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | sed "s|^$ROOT/|L10: |"
    exit 1
fi
exit 0
