#!/usr/bin/env bash
# L01 — no literal `$HOME/dotfiles` or `~/dotfiles` in workstation/engine
# code. Identity location is parameterized via `$MESH_IDENTITY_DIR`
# (preferred) or `$DOTFILES_DIR` (legacy fallback).
#
# Allowlist: the canonical fallback form `${VAR:-$HOME/dotfiles}` or
# `${VAR:=$HOME/dotfiles}` is accepted — the literal is a default, the envar
# drives resolution. Anything else (bare literal, concatenation) is flagged.
#
# Spec: §C21. Phase 5 emerged item.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

candidates=$(grep -rnE '^[^#]*(\$HOME/dotfiles|~/dotfiles)' \
    --include='*.sh' --include='*.zsh' \
    --exclude-dir=tests --exclude-dir=.git --exclude-dir=docs --exclude-dir=archive \
    --exclude-dir=lints \
    "$ROOT/scripts" "$ROOT/topics" "$ROOT/bin" 2>/dev/null || true)

[[ -z "$candidates" ]] && exit 0

# Filter out lines using ${VAR:-$HOME/dotfiles} or ${VAR:=$HOME/dotfiles}.
hits=$(printf '%s\n' "$candidates" \
    | grep -vE '\$\{[A-Za-z_][A-Za-z0-9_]*:[-=]\$HOME/dotfiles' \
    || true)

if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | sed "s|^$ROOT/|L01: |; s|$| (use \${VAR:-\$HOME/dotfiles} or \$MESH_IDENTITY_DIR)|"
    exit 1
fi
exit 0
