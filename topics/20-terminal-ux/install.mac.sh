#!/usr/bin/env bash
# 20-terminal-ux (mac): modern CLI stack + Nerd Font.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

: "${BREW_BIN:?BREW_BIN not set — run through bootstrap.sh}"

# Extra zsh UX parity with ble.sh on Linux bash. Installation here; the
# sourcing/ordering/bindkey plumbing lives in dotfiles/shell/zshrc.local.
#
#   - zsh-completions              extra completions (docker, npm, kubectl…)
#                                  auto-added to fpath by 30-shell before compinit.
#   - zsh-autosuggestions          Fish-like ghost-text from history + completion.
#   - zsh-syntax-highlighting      live coloring (main/brackets/pattern/cursor).
#   - zsh-history-substring-search up/down arrow → search history by substring
#                                  of the current buffer (Fish-like).
#   - atuin                        SQLite-backed shell history replacement with
#                                  fuzzy Ctrl-R + cross-machine sync (manual
#                                  `atuin register`/`atuin import zsh` first time).
#   - forgit                       fzf-powered git helpers (ga, gd, gco, gi, …).
#   - zsh-you-should-use           nags when you skip an alias you defined.
pkgs=(fzf bat eza zoxide ripgrep fd starship lazygit git-delta tmux \
      zsh-completions zsh-autosuggestions zsh-syntax-highlighting \
      zsh-history-substring-search atuin forgit zsh-you-should-use)

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

# ─── fzf-tab (not in brew-core) ───
# fzf-tab replaces the default TAB completion menu with an fzf fuzzy picker
# that has a live preview pane. Only distributed via GitHub (Aloxaf/fzf-tab).
# Clone once into ~/.local/share/fzf-tab; dotfiles/shell/zshrc.local sources
# from that path. Idempotent: pull if already cloned.
FZF_TAB_DIR="$HOME/.local/share/fzf-tab"
if [ -d "$FZF_TAB_DIR/.git" ]; then
    info "fzf-tab already cloned — pulling updates"
    git -C "$FZF_TAB_DIR" pull --quiet --ff-only 2>/dev/null && ok "fzf-tab up to date" \
        || warn "fzf-tab pull failed (non-fatal)"
else
    info "cloning Aloxaf/fzf-tab → $FZF_TAB_DIR"
    git clone --quiet --depth 1 https://github.com/Aloxaf/fzf-tab "$FZF_TAB_DIR"
    ok "fzf-tab cloned"
fi

# ─── Configure iTerm2 to use the Nerd Font (if iTerm2 is installed) ───
# Installing the font places the .ttf in ~/Library/Fonts but terminals don't
# auto-pick it up — each terminal app needs its own config edit. iTerm2 is
# the default focus; other terminals (Ghostty/Kitty/Warp) require separate
# config files the user drops in themselves.
if [ -x "$HERE/scripts/configure-iterm2-font.sh" ]; then
    bash "$HERE/scripts/configure-iterm2-font.sh" || warn "iTerm2 font config failed (non-fatal)"
fi

ok "20-terminal-ux done"
