#!/usr/bin/env bash
# L04 — no `eval $(...)` constructs. Eval on command substitution is a known
# injection vector; if env-driven evaluation is truly needed, use a sentinel
# helper that explicitly validates input.
# Spec: §C21. Phase 5 Task 5.2.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

hits=$(grep -rnE '^[^#]*\beval[[:space:]]+\$\(' \
    --include='*.sh' --include='*.zsh' \
    --exclude-dir=tests --exclude-dir=.git --exclude-dir=archive \
    "$ROOT/scripts" "$ROOT/topics" "$ROOT/bin" 2>/dev/null || true)

if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | sed "s|^$ROOT/|L04: |"
    exit 1
fi
exit 0
