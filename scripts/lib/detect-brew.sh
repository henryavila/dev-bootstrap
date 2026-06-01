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
    "/home/linuxbrew/.linuxbrew/bin/brew"
)

# /Volumes/External*/homebrew — glob handles the macOS mount-point
# disambiguation case: when a system LaunchDaemon's StandardErrorPath
# triggers boot-time mkdir of `/Volumes/External/...` before the real
# external disk mounts, diskarbitrationd falls back to mounting the
# real disk at `/Volumes/External 1` (or `External 2`, etc). Without
# this glob, recovery scripts that depend on detect-brew.sh fail to
# locate brew and abort.
#
# Bash 3.2 quirk (Mac default): `shopt -p <option_off>` exits 1, which
# combined with `set -e` aborts the script. Use `shopt -q` to detect
# state, then restore explicitly.
_nullglob_was_set=0
shopt -q nullglob && _nullglob_was_set=1
shopt -s nullglob
for cand in /Volumes/External*/homebrew/bin/brew; do
    candidates+=( "$cand" )
done
[[ $_nullglob_was_set -eq 0 ]] && shopt -u nullglob
unset _nullglob_was_set

for cand in "${candidates[@]}"; do
    if [[ -n "$cand" ]] && [[ -x "$cand" ]]; then
        prefix="$("$cand" --prefix)"
        printf 'BREW_BIN=%q\n' "$cand"
        printf 'BREW_PREFIX=%q\n' "$prefix"
        exit 0
    fi
done

exit 1
