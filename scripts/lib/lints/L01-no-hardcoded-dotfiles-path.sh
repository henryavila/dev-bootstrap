#!/usr/bin/env bash
# L01 — no literal `$HOME/mesh-identity` (or legacy `$HOME/dotfiles`) bare
# in workstation/engine code. Identity location must be parameterized via
# `$MESH_IDENTITY_DIR`.
#
# Allowlist: the canonical fallback form `${VAR:-$HOME/mesh-identity}` or
# `${VAR:=$HOME/mesh-identity}` is accepted — the literal is a default, the
# envar drives resolution. Anything else (bare literal, concatenation) is
# flagged.
#
# Spec: §C21. Phase 5 emerged item.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

candidates=$(grep -rnE '^[^#]*(\$HOME/(mesh-identity|dotfiles)|~/(mesh-identity|dotfiles))' \
    --include='*.sh' --include='*.zsh' \
    --exclude-dir=tests --exclude-dir=.git --exclude-dir=docs --exclude-dir=archive \
    --exclude-dir=lints \
    "$ROOT/scripts" "$ROOT/topics" "$ROOT/bin" 2>/dev/null || true)

[[ -z "$candidates" ]] && exit 0

# Filter out lines using ${VAR:-$HOME/...} or ${VAR:=$HOME/...} form,
# and doc lines like "(default $HOME/mesh-identity)".
hits=$(printf '%s\n' "$candidates" \
    | grep -vE '\$\{[A-Za-z_][A-Za-z0-9_]*:[-=]\$HOME/(mesh-identity|dotfiles)' \
    | grep -vE '\(default \$HOME/(mesh-identity|dotfiles)\)' \
    || true)

if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | sed "s|^$ROOT/|L01: |; s|$| (use \${MESH_IDENTITY_DIR:-\$HOME/mesh-identity})|"
    exit 1
fi
exit 0
