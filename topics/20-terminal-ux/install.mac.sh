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
      btop dust duf gping xh sd tealdeer procs \
      neovim)

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

# ─── bat Catppuccin Mocha theme (parity with install.wsl.sh) ──────────
BAT_THEMES_DIR="$HOME/.config/bat/themes"
BAT_THEME_FILE="$BAT_THEMES_DIR/Catppuccin Mocha.tmTheme"
if command -v bat >/dev/null 2>&1; then
    if [ ! -f "$BAT_THEME_FILE" ]; then
        info "downloading Catppuccin Mocha theme for bat"
        mkdir -p "$BAT_THEMES_DIR"
        curl -fsSL -o "$BAT_THEME_FILE" \
            "https://github.com/catppuccin/bat/raw/main/themes/Catppuccin%20Mocha.tmTheme"
    fi
    bat cache --build >/dev/null 2>&1 || warn "bat cache --build failed (non-fatal)"
    ok "bat theme: Catppuccin Mocha ready"
fi

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

# ─── Post-install: zsh as default login shell ────────────────────────
# Mac usually already defaults to /bin/zsh, but the brew-installed zsh
# at $BREW_PREFIX/bin/zsh is a distinct binary — we make brew zsh
# authoritative so the plugin stack + version are the ones the user
# actually runs.
#
# Default: attempt `sudo chsh` using the cached sudo ticket from
# bootstrap.sh's upfront `sudo -v`. Mac has no `usermod`; chsh is the
# only path, but it normally accepts the sudo cache without prompting.
#
# Override: CHSH_AUTO=0 bash bootstrap.sh  to skip the auto attempt.
if command -v zsh >/dev/null 2>&1; then
    zsh_bin="$(command -v zsh)"
    current_shell="$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}')"

    if [ -n "$current_shell" ] && [ "$current_shell" = "$zsh_bin" ]; then
        ok "zsh is the default login shell"
    elif [ "${CHSH_AUTO:-1}" = "1" ]; then
        info "attempting to set zsh as default login shell"

        # brew-installed zsh path is NOT in /etc/shells by default on
        # macOS (the OS lists /bin/zsh, not $BREW_PREFIX/bin/zsh).
        # Adding it ourselves avoids a confusing chsh failure for
        # users running brew zsh instead of system zsh.
        if ! grep -qxF "$zsh_bin" /etc/shells 2>/dev/null; then
            info "adding $zsh_bin to /etc/shells"
            echo "$zsh_bin" | sudo tee -a /etc/shells >/dev/null 2>&1 || true
        fi

        # Sudo strategy (mirror of install.wsl.sh):
        #   1. `-n` fast-path when the upfront ticket is still warm.
        #   2. Interactive fallback on a TTY, because 20-terminal-ux
        #      runs after many minutes of brew installs which easily
        #      exceed the default timestamp_timeout. Skipped in
        #      NON_INTERACTIVE so automation never stalls for input.
        chsh_ok=0
        if sudo -n chsh -s "$zsh_bin" "$USER" 2>/dev/null; then
            chsh_ok=1
        elif [ -t 0 ] && [ -t 1 ] && [ "${NON_INTERACTIVE:-0}" != "1" ]; then
            info "sudo ticket expired during this run — one prompt to finish chsh"
            if sudo chsh -s "$zsh_bin" "$USER" </dev/tty 2>/dev/null; then
                chsh_ok=1
            fi
        fi

        if [ "$chsh_ok" = "1" ]; then
            new_shell="$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}')"
            if [ "$new_shell" = "$zsh_bin" ]; then
                ok "default login shell set to $zsh_bin"
                followup info \
"zsh set as default login shell. Open a new Terminal tab (or run
'exec zsh') to start using it; the current session is unaffected."
            else
                # chsh returned 0 but DirectoryService is unchanged —
                # unusual on a personal Mac, more common on MDM /
                # domain-bound enterprise macs where the directory is
                # authoritative.
                followup manual \
"automatic chsh returned success but DirectoryService is unchanged
— your account may be MDM/directory-managed.
Try:  chsh -s \"$zsh_bin\"   (prompts for your login password)"
            fi
        else
            followup manual \
"could not set default shell automatically (sudo chsh refused).
Run manually:  chsh -s \"$zsh_bin\"   (prompts for your login password)
Skip the auto-attempt next time:  CHSH_AUTO=0 bash bootstrap.sh"
        fi
    else
        followup manual \
"zsh installed but NOT the default login shell (currently: $current_shell).
CHSH_AUTO=0 — auto-attempt skipped.
Run:  chsh -s \"$zsh_bin\"   (prompts for your login password)"
    fi
fi

# ─── Post-install advisory: atuin login (browser OAuth) ─────────────
# `atuin status` is the reliable login indicator — v18 stopped creating
# ~/.local/share/atuin/session (credential moved to the daemon/SQLite
# layer), so filesystem-based detection gave a permanent false-negative
# advisory on already-logged-in machines.
if command -v atuin >/dev/null 2>&1; then
    if ! atuin status >/dev/null 2>&1; then
        followup manual \
"atuin installed but not logged in (no cross-machine history yet).
Run:  atuin login
  (opens a browser → atuin.sh OAuth; no password or key needed)"
    else
        ok "atuin logged in (cross-machine history active)"
    fi
fi

ok "20-terminal-ux done"
