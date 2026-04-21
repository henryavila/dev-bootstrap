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
      zsh-history-substring-search atuin forgit zsh-you-should-use \
      btop dust duf gping xh sd tealdeer procs)

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

# ─── fzf-tab + Powerlevel10k + zinit (not in brew-core) ───
# Clone each into ~/.local/share/ with the same layout as the Linux
# install — dotfiles/shell/zshrc.local sources from the same paths on
# both platforms. Idempotent: pull if already cloned.
SHARE_DIR="$HOME/.local/share"
mkdir -p "$SHARE_DIR"

clone_or_pull_mac() {
    local repo="$1" dest="$2" label="$3"
    if [ -d "$dest/.git" ]; then
        info "$label already cloned — pulling updates"
        git -C "$dest" pull --quiet --ff-only 2>/dev/null \
            && ok "$label up to date" \
            || warn "$label pull failed (non-fatal)"
        git -C "$dest" submodule update --init --recursive --quiet 2>/dev/null || true
    else
        info "cloning $repo → $dest"
        git clone --quiet --depth 1 --recurse-submodules \
            "https://github.com/$repo" "$dest"
        ok "$label cloned"
    fi
}

clone_or_pull_mac Aloxaf/fzf-tab          "$SHARE_DIR/fzf-tab"          fzf-tab
clone_or_pull_mac romkatv/powerlevel10k   "$SHARE_DIR/powerlevel10k"    powerlevel10k

# zinit — installer owns its directory; pipe "n" so it leaves ~/.zshrc alone
# (dev-bootstrap's 30-shell template owns that file).
ZINIT_DIR="$HOME/.local/share/zinit"
if [ -f "$ZINIT_DIR/zinit.git/zinit.zsh" ]; then
    ok "zinit already installed"
else
    info "installing zinit"
    mkdir -p "$ZINIT_DIR"
    yes n | bash -c "$(curl --fail --show-error --silent --location \
        https://raw.githubusercontent.com/zdharma-continuum/zinit/HEAD/scripts/install.sh)" \
        >/dev/null 2>&1 || warn "zinit install script returned non-zero (checking state)"
    if [ -f "$ZINIT_DIR/zinit.git/zinit.zsh" ]; then
        ok "zinit installed"
    else
        warn "zinit install failed — shell will degrade gracefully (non-fatal)"
    fi
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
