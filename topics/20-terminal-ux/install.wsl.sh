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
          btop duf gping sd tealdeer)

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

# ─── atuin (binary installer) ──────────────────────────────────────────
# Uses atuin's official setup script: downloads the matching binary for
# the current arch into ~/.local/bin/atuin. Idempotent (no-op if present).
# First run (per machine) still requires: atuin register|login + atuin import bash|zsh.
if ! command -v atuin >/dev/null 2>&1; then
    info "installing atuin via setup.atuin.sh"
    curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh
else
    ok "atuin already installed"
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

# ─── Post-install advisory: shell migration ──────────────────────────
# This script is idempotent and safe to re-run on ANY machine — it's the
# canonical path to migrate bash → zsh, not just a first-time installer.
# We never run `chsh` silently (it requires the login password and would
# block the script), so we advise the user what's left to do interactively.
if command -v zsh >/dev/null 2>&1; then
    current_shell="$(getent passwd "$USER" 2>/dev/null | cut -d: -f7)"
    if [ "$current_shell" != "$(command -v zsh)" ]; then
        warn "zsh is installed but NOT the default login shell ($current_shell)."
        info "To finish the bash → zsh migration, run:"
        info "    chsh -s \"\$(command -v zsh)\""
        info "then log out / log back in (or \`exec zsh\` to try it first)."
    else
        ok "zsh is already the default login shell"
    fi
fi

ok "20-terminal-ux done"
