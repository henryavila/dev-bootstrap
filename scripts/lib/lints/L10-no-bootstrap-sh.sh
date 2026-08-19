#!/usr/bin/env bash
# L10 — no `bootstrap.sh` / stale `dev-bootstrap` entrypoints in operator paths.
# Comments and docs are exempt (they may reference history). Tests excluded.
# Spec: §C21. Phase 5 Task 5.2. Extended 2026-08-19 for windows/ + root install.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

hits=$(grep -rnE '^[^#]*\bbootstrap\.sh\b' \
    --include='*.sh' --include='*.zsh' --include='*.ps1' \
    --exclude-dir=tests --exclude-dir=.git --exclude-dir=docs --exclude-dir=archive \
    "$ROOT/scripts" "$ROOT/topics" "$ROOT/bin" "$ROOT/windows" "$ROOT/install" 2>/dev/null || true)

# Root `install` is a file, not a dir — grep path above may no-op on some greps;
# scan it explicitly.
if [[ -f "$ROOT/install" ]]; then
    file_hits=$(grep -nE '^[^#]*\bbootstrap\.sh\b' "$ROOT/install" 2>/dev/null || true)
    [[ -n "$file_hits" ]] && hits+=$'\n'"$ROOT/install:$file_hits"
fi

# Stale GitHub clone URL in entrypoints (not historical changelog prose).
stale=$(grep -rnE 'henryavila/dev-bootstrap(\.git)?([[:space:]"'\'']|$)' \
    --include='*.sh' --include='*.ps1' \
    --exclude-dir=tests --exclude-dir=.git --exclude-dir=docs --exclude-dir=archive \
    "$ROOT/windows" "$ROOT/install" "$ROOT/bin" 2>/dev/null || true)
if [[ -f "$ROOT/install" ]]; then
    ih=$(grep -nE 'henryavila/dev-bootstrap(\.git)?([[:space:]"'\'']|$)' "$ROOT/install" 2>/dev/null || true)
    [[ -n "$ih" ]] && stale+=$'\n'"$ROOT/install:$ih"
fi

rc=0
if [[ -n "${hits//[$'\n']/}" ]]; then
    printf '%s\n' "$hits" | sed '/^$/d' | sed "s|^$ROOT/|L10: |"
    rc=1
fi
if [[ -n "${stale//[$'\n']/}" ]]; then
    printf '%s\n' "$stale" | sed '/^$/d' | sed "s|^$ROOT/|L10-stale-repo: |"
    rc=1
fi
exit "$rc"
