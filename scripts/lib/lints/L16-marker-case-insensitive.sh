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

# Filter out lines whose grep flags include -i (alone, -qi, -iq, -ci, etc.) or
# --ignore-case. Token-aware: scan every option token after "grep " until the
# first non-option (the pattern). Recognizes -i in any short-flag cluster
# regardless of position, and the long form --ignore-case.
hits=$(printf '%s\n' "$candidates" \
    | awk '
    {
        line = $0
        if (!match(line, /grep[[:space:]]+/)) { print; next }
        args = substr(line, RSTART + RLENGTH)
        n = split(args, tokens, /[[:space:]]+/)
        has_i = 0
        for (i = 1; i <= n; i++) {
            t = tokens[i]
            if (t == "") continue
            if (substr(t, 1, 1) != "-") break
            if (t == "--") break
            if (t == "--ignore-case") { has_i = 1; break }
            if (substr(t, 1, 2) == "--") continue
            if (index(substr(t, 2), "i") > 0) { has_i = 1; break }
        }
        if (!has_i) print
    }' 2>/dev/null || true)

if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | sed "s|^$ROOT/|L16: |; s|$| (use grep -qi for case-insensitive marker match)|"
    exit 1
fi
exit 0
