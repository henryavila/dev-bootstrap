#!/usr/bin/env bash
# L12 — workstation/engine code must not reference identity-only paths.
# `.ai/memory/` and `CLAUDE.md` live in mesh-identity (private repo); any
# mention in workstation indicates leaked coupling between layers.
# Spec: §C21 / D-A5. Phase 5 emerged item.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

hits=$(grep -rnE '^[^#]*(\.ai/memory|CLAUDE\.md)' \
    --include='*.sh' --include='*.zsh' \
    --exclude-dir=tests --exclude-dir=.git --exclude-dir=docs --exclude-dir=archive \
    "$ROOT/scripts" "$ROOT/topics" "$ROOT/bin" 2>/dev/null || true)

if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | sed "s|^$ROOT/|L12: |"
    exit 1
fi
exit 0
