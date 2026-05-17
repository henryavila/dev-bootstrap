#!/usr/bin/env bash
# L06 — no inline secrets / API keys. Catches assignments of secret-shaped
# names to long alphanumeric literals. Real secrets live in mesh-identity
# (private repo) or are sourced from env at runtime.
# Spec: §C21. Phase 5 Task 5.2.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

hits=$(grep -rinE "^[^#]*(api[_-]?key|secret|password|token)[[:space:]]*=[[:space:]]*[\"'][a-zA-Z0-9_/+=-]{20,}[\"']" \
    --include='*.sh' --include='*.zsh' \
    --exclude-dir=tests --exclude-dir=.git --exclude-dir=archive \
    "$ROOT/scripts" "$ROOT/topics" "$ROOT/bin" 2>/dev/null || true)

if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | sed "s|^$ROOT/|L06: |"
    exit 1
fi
exit 0
