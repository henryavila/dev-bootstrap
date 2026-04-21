#!/usr/bin/env bash
# 20-terminal-ux (mac): modern CLI stack + Nerd Font.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

: "${BREW_BIN:?BREW_BIN not set — run through bootstrap.sh}"

# zsh-completions: extra community-maintained completions (docker, npm, etc.)
# that aren't bundled with their respective brew formulas. The 30-shell
# zshrc template auto-detects $HOMEBREW_PREFIX/share/zsh-completions and
# adds it to fpath before compinit.
pkgs=(fzf bat eza zoxide ripgrep fd starship lazygit git-delta tmux zsh-completions)

for p in "${pkgs[@]}"; do
    if "$BREW_BIN" list --formula "$p" >/dev/null 2>&1; then
        ok "$p already installed"
    else
        info "brew install $p"
        "$BREW_BIN" install "$p"
    fi
done

# Nerd Font: CaskaydiaCove (Cascadia Code NF)
if "$BREW_BIN" list --cask font-caskaydia-cove-nerd-font >/dev/null 2>&1; then
    ok "font-caskaydia-cove-nerd-font already installed"
else
    info "brew install --cask font-caskaydia-cove-nerd-font"
    "$BREW_BIN" install --cask font-caskaydia-cove-nerd-font
fi

ok "20-terminal-ux done"
