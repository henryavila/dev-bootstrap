#!/usr/bin/env bash
# L16 — grep checks for `mesh-managed:` marker must use -i (case-insensitive)
# because real-world files have `MANAGED:` uppercase and legacy
# `dotfiles-managed:` forms. The managed-block.sh lib already does the right
# thing; this lint catches drift in NEW callers.
# Spec: §C21. Phase 5 Task 5.2.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

# Match: grep ... 'mesh-managed:' ...  on a non-comment line. We want callers
# missing the -i (or -qi/-iq) flag. Two-pass: first find all grep-of-marker
# uses, then filter out ones that include -i in the grep flags.
candidates=$(grep -rnE "^[^#]*grep[[:space:]][^|]*['\"]mesh-managed:" \
    --include='*.sh' --include='*.zsh' \
    --exclude-dir=tests --exclude-dir=.git --exclude-dir=archive \
    "$ROOT/scripts" "$ROOT/topics" "$ROOT/bin" 2>/dev/null || true)

[[ -z "$candidates" ]] && exit 0

# Filter out lines whose grep flags include -i (alone, -qi, -iq, -ci, etc.).
hits=$(printf '%s\n' "$candidates" \
    | grep -vE "grep[[:space:]]+-[A-Za-z]*i[A-Za-z]*[[:space:]]" \
    | grep -vE "grep[[:space:]]+-i[[:space:]]" 2>/dev/null || true)

if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | sed "s|^$ROOT/|L16: |; s|$| (use grep -qi for case-insensitive marker match)|"
    exit 1
fi
exit 0
