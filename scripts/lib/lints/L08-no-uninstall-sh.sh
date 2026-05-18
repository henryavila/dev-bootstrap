#!/usr/bin/env bash
# L08 — no `uninstall.sh` references in code. The file was renamed to
# topic-cleanup.sh during Phase 2 Task 2.4 (commit 237e34d); new references
# reintroduce a dead name and break the F-A5 invariant.
# Spec: §C21 / F-A5. Phase 5 emerged item.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

hits=$(grep -rnE '^[^#]*\buninstall\.sh\b' \
    --include='*.sh' --include='*.zsh' \
    --exclude-dir=tests --exclude-dir=.git --exclude-dir=docs --exclude-dir=archive \
    "$ROOT/scripts" "$ROOT/topics" "$ROOT/bin" 2>/dev/null || true)

if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | sed "s|^$ROOT/|L08: |"
    exit 1
fi
exit 0
