#!/usr/bin/env bash
# 20-terminal-ux (mac): modern CLI stack + Nerd Font.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

: "${BREW_BIN:?BREW_BIN not set — run through bootstrap.sh}"

# Extra zsh UX parity with ble.sh on Linux bash:
#   - zsh-completions        extra community-maintained completions (docker,
#                            npm, kubectl, etc.) auto-added to fpath by the
#                            30-shell zshrc template before compinit.
#   - zsh-autosuggestions    Fish-like ghost-text suggestions from history
#                            (type, see grey suggestion, → arrow to accept).
#   - zsh-syntax-highlighting Live syntax coloring (commands green, errors
#                            red, strings colored). MUST be sourced LAST in
#                            ~/.zshrc.local — the dotfiles layer handles the
#                            sourcing order, bootstrap just installs the
#                            formulas.
pkgs=(fzf bat eza zoxide ripgrep fd starship lazygit git-delta tmux \
      zsh-completions zsh-autosuggestions zsh-syntax-highlighting)

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
