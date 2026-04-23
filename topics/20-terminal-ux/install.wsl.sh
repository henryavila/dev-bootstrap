#!/usr/bin/env bash
# 20-terminal-ux (WSL): modern CLI stack + zsh plugin parity with macOS.
# Target: Ubuntu 22.04/24.04 under WSL2.
#
# Parity strategy (matches install.mac.sh):
#   - Modern CLI tools: fzf bat eza zoxide ripgrep fd-find → all via apt
#   - zsh core + 2 plugins available in apt: zsh, zsh-autosuggestions, zsh-syntax-highlighting
#   - The other 5 plugins (zsh-completions, zsh-history-substring-search,
#     fzf-tab, forgit, alias-tips, zsh-abbr, zsh-you-should-use) are NOT
#     packaged in Ubuntu 24.04 apt — we clone each into ~/.local/share/
#     so zshrc.local sources them from the same path regardless of OS.
#   - atuin: binary via setup.atuin.sh (no cargo needed).
#   - starship, lazygit, git-delta: existing install blocks preserved.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

# ─── apt packages ───────────────────────────────────────────────────────
# zsh-autosuggestions + zsh-syntax-highlighting install to /usr/share/ with
# stable paths — zshrc.local's apt-fallback branch points there.
# Phase E modern CLI additions: btop (top), duf (df), gping (ping), sd
# (sed), tealdeer (tldr). Not in apt on 24.04: procs, dust, xh — install
# via cargo later if needed.
apt_pkgs=(fzf bat eza zoxide ripgrep fd-find
          zsh zsh-autosuggestions zsh-syntax-highlighting
          btop duf gping sd tealdeer
          neovim)

missing=()
for p in "${apt_pkgs[@]}"; do
    if dpkg -s "$p" >/dev/null 2>&1; then
        ok "$p already installed"
    else
        missing+=("$p")
    fi
done

if [[ "${#missing[@]}" -gt 0 ]]; then
    info "apt installing: ${missing[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y -qq "${missing[@]}"
fi

# ─── git-cloned zsh plugins ────────────────────────────────────────────
# Parity with install.mac.sh's brew formulas that don't exist in apt.
# Each clone is idempotent: pull if present, clone if absent.
SHARE_DIR="$HOME/.local/share"
mkdir -p "$SHARE_DIR"

clone_or_pull() {
    local repo="$1" dest="$2" label="$3"
    if [ -d "$dest/.git" ]; then
        info "$label already cloned — pulling updates"
        git -C "$dest" pull --quiet --ff-only 2>/dev/null \
            && ok "$label up to date" \
            || warn "$label pull failed (non-fatal)"
        # Ensure submodules stay in sync even on pull-only idempotent runs
        # (zsh-abbr pulls in zsh-job-queue as a git submodule).
        git -C "$dest" submodule update --init --recursive --quiet 2>/dev/null || true
    else
        info "cloning $repo → $dest"
        # --recurse-submodules: zsh-abbr needs zsh-job-queue. Harmless for
        # repos without submodules (git just skips the recursion).
        git clone --quiet --depth 1 --recurse-submodules \
            "https://github.com/$repo" "$dest"
        ok "$label cloned"
    fi
}

clone_or_pull zsh-users/zsh-completions                "$SHARE_DIR/zsh-completions"                zsh-completions
clone_or_pull zsh-users/zsh-history-substring-search   "$SHARE_DIR/zsh-history-substring-search"   zsh-history-substring-search
clone_or_pull Aloxaf/fzf-tab                           "$SHARE_DIR/fzf-tab"                        fzf-tab
clone_or_pull wfxr/forgit                              "$SHARE_DIR/forgit"                         forgit
clone_or_pull djui/alias-tips                          "$SHARE_DIR/alias-tips"                     alias-tips
clone_or_pull olets/zsh-abbr                           "$SHARE_DIR/zsh-abbr"                       zsh-abbr
clone_or_pull MichaelAquilina/zsh-you-should-use       "$SHARE_DIR/zsh-you-should-use"             zsh-you-should-use

# Phase C: Powerlevel10k as a standalone clone (also turbo-loaded via
# zinit in zshrc.local — this parallel copy is the graceful-degrade
# fallback if zinit isn't ready on the first login).
clone_or_pull romkatv/powerlevel10k                    "$SHARE_DIR/powerlevel10k"                  powerlevel10k

# ─── Snapshot rc files (protect .bashrc/.zshrc from shell-based installers) ─
# The zinit installer and setup.atuin.sh below both append content directly
# to ~/.bashrc / ~/.zshrc. That breaks the managed-by-marker invariant and
# makes 30-shell's deploy refuse to overwrite the no-longer-pristine rc on
# first run. Snapshot → let them run → restore (or delete if the installer
# created the file from scratch). Shell init for both tools lives in the
# .bashrc.d/.zshrc.d fragments instead — those stay managed and testable.
rc_bashrc_existed=0 rc_zshrc_existed=0
rc_bashrc_snapshot="" rc_zshrc_snapshot=""
if [[ -f "$HOME/.bashrc" ]]; then
    rc_bashrc_existed=1
    rc_bashrc_snapshot="$(mktemp)"
    cp -p "$HOME/.bashrc" "$rc_bashrc_snapshot"
fi
if [[ -f "$HOME/.zshrc" ]]; then
    rc_zshrc_existed=1
    rc_zshrc_snapshot="$(mktemp)"
    cp -p "$HOME/.zshrc" "$rc_zshrc_snapshot"
fi

# Phase C: zinit — installed to its canonical location
# (~/.local/share/zinit/zinit.git) so the official installer path
# matches. Idempotent: re-running zinit's installer with an existing
# dir is a no-op. We pipe "n" to the "edit ~/.zshrc?" prompt because
# dev-bootstrap's 30-shell template owns that file; zinit loading
# lives in shell/zshrc.local instead.
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

# ─── atuin (binary installer) ──────────────────────────────────────────
# Uses atuin's official setup script: downloads the matching binary for
# the current arch into ~/.atuin/bin. Idempotent (no-op if present).
# First run (per machine) still requires: atuin register|login + atuin import bash|zsh.
# Shell init wiring lives in the .bashrc.d/.zshrc.d fragments (see templates);
# the surrounding rc-snapshot block restores anything setup.atuin.sh touches.
if ! command -v atuin >/dev/null 2>&1; then
    info "installing atuin via setup.atuin.sh"
    curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh
else
    ok "atuin already installed"
fi

# ─── Restore rc files (pairs with the snapshot block before zinit) ─────
# zinit and atuin are the two risk points; both are now installed. Put
# .bashrc/.zshrc back to their pre-topic state, or remove them entirely
# if they didn't exist before — 30-shell will deploy managed templates.
if [[ "$rc_bashrc_existed" == "1" ]]; then
    cp -p "$rc_bashrc_snapshot" "$HOME/.bashrc"
    rm -f "$rc_bashrc_snapshot"
elif [[ -f "$HOME/.bashrc" ]]; then
    rm -f "$HOME/.bashrc"
fi
if [[ "$rc_zshrc_existed" == "1" ]]; then
    cp -p "$rc_zshrc_snapshot" "$HOME/.zshrc"
    rm -f "$rc_zshrc_snapshot"
elif [[ -f "$HOME/.zshrc" ]]; then
    rm -f "$HOME/.zshrc"
fi

# ─── bat Catppuccin Mocha theme ───────────────────────────────────────
# bat's built-in themes are fine but don't match the rest of the stack.
# The Catppuccin project ships a .tmTheme file; drop it into bat's user
# themes dir and rebuild the cache so `bat --list-themes` + BAT_THEME env
# var pick it up. Idempotent: skips download if the file is already there.
BAT_THEMES_DIR="$HOME/.config/bat/themes"
BAT_THEME_FILE="$BAT_THEMES_DIR/Catppuccin Mocha.tmTheme"
# Pick the right binary name up front (Debian/Ubuntu ship it as `batcat`).
BAT_BIN=""
if command -v bat >/dev/null 2>&1; then
    BAT_BIN="bat"
elif command -v batcat >/dev/null 2>&1; then
    BAT_BIN="batcat"
fi
if [ -n "$BAT_BIN" ]; then
    if [ ! -f "$BAT_THEME_FILE" ]; then
        info "downloading Catppuccin Mocha theme for bat"
        mkdir -p "$BAT_THEMES_DIR"
        curl -fsSL -o "$BAT_THEME_FILE" \
            "https://github.com/catppuccin/bat/raw/main/themes/Catppuccin%20Mocha.tmTheme"
    fi
    # Rebuild cache so the new theme is discoverable. Cheap (~100ms).
    "$BAT_BIN" cache --build >/dev/null 2>&1 || warn "$BAT_BIN cache --build failed (non-fatal)"
    ok "bat theme: Catppuccin Mocha ready"
fi

# ─── starship ─────────────────────────────────────────────────────────
if ! command -v starship >/dev/null 2>&1; then
    info "installing starship"
    curl -fsSL https://starship.rs/install.sh | sh -s -- --yes
else
    ok "starship already installed"
fi

# ─── lazygit ──────────────────────────────────────────────────────────
if ! command -v lazygit >/dev/null 2>&1; then
    info "installing lazygit"
    lg_version="$(curl -fsSL "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | jq -r '.tag_name' | sed 's/^v//')"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/lg.tgz" "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${lg_version}_Linux_x86_64.tar.gz"
    tar -C "$tmp" -xzf "$tmp/lg.tgz" lazygit
    sudo install -m 0755 "$tmp/lazygit" /usr/local/bin/lazygit
    rm -rf "$tmp"
else
    ok "lazygit already installed"
fi

# ─── git-delta ────────────────────────────────────────────────────────
if ! command -v delta >/dev/null 2>&1; then
    info "installing git-delta"
    delta_version="$(curl -fsSL "https://api.github.com/repos/dandavison/delta/releases/latest" | jq -r '.tag_name')"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/delta.deb" "https://github.com/dandavison/delta/releases/download/${delta_version}/git-delta_${delta_version}_amd64.deb"
    sudo dpkg -i "$tmp/delta.deb"
    rm -rf "$tmp"
else
    ok "git-delta already installed"
fi

# ─── dust / xh / procs (Rust binaries not in apt 24.04) ──────────────
# Installed as single-file binaries into ~/.local/bin. That directory is
# already on PATH via 30-shell (bashrc/zshrc templates), so no sudo and
# no /etc/bashrc-level changes. Each block is idempotent.
mkdir -p "$HOME/.local/bin"

if ! command -v dust >/dev/null 2>&1; then
    info "installing dust (bootandy/dust)"
    dust_version="$(curl -fsSL "https://api.github.com/repos/bootandy/dust/releases/latest" | jq -r '.tag_name')"
    tmp="$(mktemp -d)"
    # Asset name: dust-vX.Y.Z-x86_64-unknown-linux-gnu.tar.gz, binary at <dir>/dust
    # (the `du-dust_*` .deb package also exists but we stick to user-level install).
    curl -fsSL -o "$tmp/dust.tgz" \
        "https://github.com/bootandy/dust/releases/download/${dust_version}/dust-${dust_version}-x86_64-unknown-linux-gnu.tar.gz"
    tar -C "$tmp" -xzf "$tmp/dust.tgz" --strip-components=1
    install -m 0755 "$tmp/dust" "$HOME/.local/bin/dust"
    rm -rf "$tmp"
    ok "dust installed → ~/.local/bin/dust"
else
    ok "dust already installed"
fi

if ! command -v xh >/dev/null 2>&1; then
    info "installing xh (ducaale/xh)"
    xh_version="$(curl -fsSL "https://api.github.com/repos/ducaale/xh/releases/latest" | jq -r '.tag_name')"
    tmp="$(mktemp -d)"
    # Asset name: xh-vX.Y.Z-x86_64-unknown-linux-musl.tar.gz, binary at <dir>/xh
    curl -fsSL -o "$tmp/xh.tgz" \
        "https://github.com/ducaale/xh/releases/download/${xh_version}/xh-${xh_version}-x86_64-unknown-linux-musl.tar.gz"
    tar -C "$tmp" -xzf "$tmp/xh.tgz" --strip-components=1
    install -m 0755 "$tmp/xh" "$HOME/.local/bin/xh"
    rm -rf "$tmp"
    ok "xh installed → ~/.local/bin/xh"
else
    ok "xh already installed"
fi

if ! command -v procs >/dev/null 2>&1; then
    info "installing procs (dalance/procs)"
    procs_version="$(curl -fsSL "https://api.github.com/repos/dalance/procs/releases/latest" | jq -r '.tag_name')"
    tmp="$(mktemp -d)"
    # procs ships a zip (not tar.gz) with `procs` at the root
    curl -fsSL -o "$tmp/procs.zip" \
        "https://github.com/dalance/procs/releases/download/${procs_version}/procs-${procs_version}-x86_64-linux.zip"
    unzip -q -o "$tmp/procs.zip" -d "$tmp"
    install -m 0755 "$tmp/procs" "$HOME/.local/bin/procs"
    rm -rf "$tmp"
    ok "procs installed → ~/.local/bin/procs"
else
    ok "procs already installed"
fi

# ─── Post-install: zsh as default login shell ────────────────────────
# This script is idempotent + safe to re-run on ANY machine — it's the
# canonical path to migrate bash → zsh, not just a first-time installer.
#
# Default: attempt `sudo chsh` (and `sudo usermod -s` as fallback) using
# the cached sudo ticket from bootstrap.sh's upfront `sudo -v`. Many
# single-user Ubuntu/Debian/WSL setups succeed here silently. Anything
# refusing — LDAP/SSSD-managed accounts on corporate laptops (M4 = crc),
# a restricted PAM policy, or a dropped sudo cache — falls through to
# the existing `followup manual` advisory. User is never worse off than
# the pre-auto behavior.
#
# Override: CHSH_AUTO=0 bash bootstrap.sh  to skip the auto attempt.
if command -v zsh >/dev/null 2>&1; then
    zsh_bin="$(command -v zsh)"
    current_shell="$(getent passwd "$USER" 2>/dev/null | cut -d: -f7)"

    if [ "$current_shell" = "$zsh_bin" ]; then
        ok "zsh is already the default login shell"
    elif [ "${CHSH_AUTO:-1}" = "1" ]; then
        info "attempting to set zsh as default login shell"

        # /etc/shells gate — chsh/usermod refuse a shell not listed
        # there. apt-installed /usr/bin/zsh is listed by default, but
        # defense-in-depth in case someone symlinked a custom zsh.
        if ! grep -qxF "$zsh_bin" /etc/shells 2>/dev/null; then
            info "adding $zsh_bin to /etc/shells"
            echo "$zsh_bin" | sudo tee -a /etc/shells >/dev/null 2>&1 || true
        fi

        # Try chsh first (friendlier error messages). Fall back to
        # usermod -s — some PAM policies refuse chsh but accept
        # usermod since it only writes /etc/passwd directly. Both
        # need sudo.
        #
        # Sudo strategy:
        #   1. `-n` (silent) — fast-path when bootstrap.sh's upfront
        #      `sudo -v` ticket is still valid. Covers most non-corp
        #      runs that finish under timestamp_timeout (~15min).
        #   2. Interactive fallback — 20-terminal-ux runs after many
        #      minutes of apt/brew installs; the cache often expires.
        #      On a TTY, prompt for password once. Skipped in
        #      NON_INTERACTIVE mode so CI/automation never stalls.
        chsh_ok=0
        if sudo -n chsh -s "$zsh_bin" "$USER" 2>/dev/null; then
            chsh_ok=1
        elif sudo -n usermod -s "$zsh_bin" "$USER" 2>/dev/null; then
            chsh_ok=1
        elif [ -t 0 ] && [ -t 1 ] && [ "${NON_INTERACTIVE:-0}" != "1" ]; then
            info "sudo ticket expired during this run — one prompt to finish chsh"
            if sudo chsh -s "$zsh_bin" "$USER" </dev/tty 2>/dev/null; then
                chsh_ok=1
            elif sudo usermod -s "$zsh_bin" "$USER" </dev/tty 2>/dev/null; then
                chsh_ok=1
            fi
        fi

        if [ "$chsh_ok" = "1" ]; then
            new_shell="$(getent passwd "$USER" 2>/dev/null | cut -d: -f7)"
            if [ "$new_shell" = "$zsh_bin" ]; then
                ok "default login shell set to $zsh_bin"
                followup info \
"zsh set as default login shell. Open a new terminal (or run 'exec zsh')
to start using it; the current session is unaffected."
            else
                # Exit 0 but /etc/passwd unchanged = account is managed
                # externally (LDAP/SSSD/AD). /etc/passwd writes appear
                # successful but aren't authoritative.
                followup manual \
"automatic chsh appeared to succeed but /etc/passwd is unchanged
— your account is likely managed externally (LDAP/SSSD/AD).
Ask IT, or try:   chsh -s \"\$(command -v zsh)\"
Then:   log out / log back in (or 'exec zsh' to try it first)"
            fi
        else
            followup manual \
"could not set default shell automatically (sudo chsh + usermod refused).
Run manually:   chsh -s \"\$(command -v zsh)\"   (prompts for password)
Then:           log out / log back in (or 'exec zsh' to try it first)
Skip the auto-attempt next time:  CHSH_AUTO=0 bash bootstrap.sh"
        fi
    else
        followup manual \
"zsh installed but NOT the default login shell (currently: $current_shell).
CHSH_AUTO=0 — auto-attempt skipped.
Run:     chsh -s \"\$(command -v zsh)\"
Then:    log out / log back in (or 'exec zsh' to try it first)"
    fi
fi

# ─── Post-install: atuin login ───────────────────────────────────────
# Run the OAuth flow inline when the bootstrap is interactive — same
# philosophy as the interactive chsh fallback above: if a human is
# present at a TTY, complete the full setup now instead of deferring
# to a post-hoc manual step.
#
# `atuin login` in v18 opens the system browser to atuin.sh/login,
# polls for the OAuth code, and writes the credential into the daemon
# state. On WSL this uses xdg-open → wslview (installed by 05-identity
# as part of wslu) to launch the Windows-side browser. If the browser
# doesn't open automatically, atuin prints the URL to stdout.
#
# Detection: `atuin status` exits 0 when logged in, non-zero with
# "Error: You are not logged in" when not. We used to check for
# ~/.local/share/atuin/session but v18 stopped creating that file
# (credential moved into daemon/SQLite), so filesystem-based detection
# gave a permanent false-negative advisory.
#
# Override: ATUIN_LOGIN_AUTO=0 bash bootstrap.sh  to skip the login
# attempt and only print the advisory. NON_INTERACTIVE=1 also disables
# the inline login so CI/automation never stalls for OAuth.
if command -v atuin >/dev/null 2>&1; then
    if atuin status >/dev/null 2>&1; then
        ok "atuin logged in (cross-machine history active)"
    elif [ "${ATUIN_LOGIN_AUTO:-1}" = "1" ] \
         && [ -t 0 ] && [ -t 1 ] \
         && [ "${NON_INTERACTIVE:-0}" != "1" ]; then
        info "atuin not logged in — running 'atuin login' (opens a browser for atuin.sh OAuth)"
        info "  if the browser does not open, copy the URL atuin prints and finish OAuth there"
        if atuin login </dev/tty; then
            ok "atuin logged in (cross-machine history active)"
        else
            followup manual \
"atuin login did not complete (user cancelled or OAuth failed).
Run manually:  atuin login
  (opens a browser → atuin.sh OAuth; no password or key needed)
Skip the auto-attempt next time:  ATUIN_LOGIN_AUTO=0 bash bootstrap.sh"
        fi
    else
        followup manual \
"atuin installed but not logged in (no cross-machine history yet).
Run:  atuin login
  (opens a browser → atuin.sh OAuth; no password or key needed)"
    fi
fi

# ─── Windows Terminal auto-config (Catppuccin + CaskaydiaCove NF) ─────
# WSL-only. Installs font Windows-side (user-level, no admin), surgical
# jq merge into settings.json. Mirrors install.mac.sh's iTerm2 step —
# every supported terminal emulator should ship pre-themed after bootstrap.
if [ -x "$HERE/scripts/configure-windows-terminal.sh" ]; then
    bash "$HERE/scripts/configure-windows-terminal.sh" || warn "Windows Terminal config failed (non-fatal)"
fi

ok "20-terminal-ux done"
