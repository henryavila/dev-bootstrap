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
apt_pkgs=(fzf bat eza zoxide ripgrep fd-find
          zsh zsh-autosuggestions zsh-syntax-highlighting)

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
    else
        info "cloning $repo → $dest"
        git clone --quiet --depth 1 "https://github.com/$repo" "$dest"
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

ok "20-terminal-ux done"
