#!/usr/bin/env bash
# 20-terminal-ux (WSL): modern CLI stack.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

apt_pkgs=(fzf bat eza zoxide ripgrep fd-find)

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

# starship (not in default apt)
if ! command -v starship >/dev/null 2>&1; then
    info "installing starship"
    curl -fsSL https://starship.rs/install.sh | sh -s -- --yes
else
    ok "starship already installed"
fi

# lazygit
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

# git-delta
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
