#!/usr/bin/env bash
# 90-editor: installs the typora-wait wrapper so `EDITOR=typora-wait` works.
# No actual app install (Typora is a GUI installed separately).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/log.sh"

mkdir -p "$HOME/.local/bin"
ok "90-editor: typora-wait wrapper will be deployed from templates/"

# ─── C15: shipped default configs ──────────────────────────────────────
# Neovim init.lua default. Identity overrides win on conflict.
_link_default_config() {
    local src="$1" dst="$2"
    [[ -f "$src" ]] || { warn "C15: source missing: $src"; return 0; }
    mkdir -p "$(dirname "$dst")"
    if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$src" ]]; then
        return 0
    fi
    if [[ -e "$dst" ]] && ! [[ -L "$dst" ]]; then
        return 0
    fi
    ln -sf "$src" "$dst"
    ok "C15 default linked: $dst → $src"
}
_link_default_config "$HERE/configs/nvim/init.lua" "$HOME/.config/nvim/init.lua"
