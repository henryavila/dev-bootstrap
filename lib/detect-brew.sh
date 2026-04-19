#!/usr/bin/env bash
# lib/detect-brew.sh — locate Homebrew in any known prefix.
# Writes "KEY=VALUE" lines to stdout on success, consumed via eval.
# Exit 0 if brew found, 1 otherwise.
#
# Usage:
#     if out=$(bash lib/detect-brew.sh); then
#         eval "$out"   # populates BREW_BIN and BREW_PREFIX
#     fi

set -euo pipefail

candidates=(
    "$(command -v brew 2>/dev/null || true)"
    "/opt/homebrew/bin/brew"
    "/usr/local/bin/brew"
    "/Volumes/External/homebrew/bin/brew"
    "/home/linuxbrew/.linuxbrew/bin/brew"
)

for cand in "${candidates[@]}"; do
    if [[ -n "$cand" ]] && [[ -x "$cand" ]]; then
        prefix="$("$cand" --prefix)"
        printf 'BREW_BIN=%q\n' "$cand"
        printf 'BREW_PREFIX=%q\n' "$prefix"
        exit 0
    fi
done

exit 1
