#!/usr/bin/env bash
# Generate zsh completion files for CLIs that expose a generator.
# Bash 3.2 compatible.

set -uo pipefail

TARGET_DIR="${ZSH_COMPLETION_TARGET_DIR:-$HOME/.local/share/zsh/site-functions}"

log()  { printf '→ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }

generate_completion() {
    local name="$1"
    local generator="$2"
    local target="$TARGET_DIR/_$name"
    local tmp="$target.tmp"

    mkdir -p "$TARGET_DIR"
    if eval "$generator" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv "$tmp" "$target"
        chmod 0644 "$target"
        ok "zsh completion generated: _$name"
    else
        rm -f "$tmp"
        warn "zsh completion skipped: _$name"
    fi
}

if command -v gh >/dev/null 2>&1; then
    generate_completion gh 'gh completion -s zsh'
fi

if command -v uv >/dev/null 2>&1; then
    generate_completion uv 'uv generate-shell-completion zsh'
fi

if command -v atuin >/dev/null 2>&1; then
    generate_completion atuin 'atuin gen-completions --shell zsh'
fi

if command -v pip >/dev/null 2>&1; then
    generate_completion pip 'pip completion --zsh'
fi
