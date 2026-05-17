#!/usr/bin/env bash
# L14 — mesh-repos.list contains only 2-layer entries (engine + workstation).
# Identity is data-only, NEVER listed here. Spec §C19. Skip-if-absent: not
# every checkout has the list (workstation default before mesh init runs).
# Spec: §C21. Phase 5 Task 5.2.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
LIST="$ROOT/mesh-repos.list"

[[ -f "$LIST" ]] || exit 0

# Valid line: <owner>/<repo>  (no path separator beyond the single slash, no
# layer-3 nesting). Blank lines and # comments allowed.
bad=$(awk 'NF == 0 || $0 ~ /^[[:space:]]*#/ { next }
           $0 !~ /^[a-zA-Z0-9._-]+\/[a-zA-Z0-9._-]+[[:space:]]*$/ { print FILENAME ":" NR ": " $0 }' \
    "$LIST" 2>/dev/null || true)

if [[ -n "$bad" ]]; then
    printf '%s\n' "$bad" | sed "s|^$ROOT/|L14: |"
    exit 1
fi
exit 0
