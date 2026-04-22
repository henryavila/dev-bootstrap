#!/usr/bin/env bash
# 05-identity (WSL/Linux): gh CLI + SSH key + GitHub registration.
# Runs BEFORE 95-dotfiles-personal so the private dotfiles clone works.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

# ─── Install gh CLI + wslu (if on WSL) ─────────────────────────────
# Ubuntu 24.04+ ships gh in the default apt repo (2.88+).
# Older Ubuntu (20.04/22.04) need the GitHub APT repo fallback.
# wslu provides `wslview`, which is the command xdg-open delegates
# to on WSL to open URLs in the user's Windows browser. Without it,
# xdg-open tries Firefox/Chrome/etc on the Linux side, finds none,
# and fails — breaking gh auth login's "Press Enter to open browser"
# flow. Harmless no-op on native Linux (the package just isn't used).

packages=(gh xclip)
# xclip: enables `gh auth login --clipboard` — auto-copies the OAuth
# device code to the OS clipboard so user can paste directly in
# browser (no mouse-select + copy). WSLg forwards xclip writes to the
# Windows clipboard transparently via RDP. Native Linux uses xclip
# with X11/Wayland (WSL-style integration via xdg).
if grep -qi microsoft /proc/version 2>/dev/null; then
    packages+=(wslu)
fi

missing=()
for p in "${packages[@]}"; do
    if dpkg -s "$p" >/dev/null 2>&1; then
        ok "$p already installed"
    else
        missing+=("$p")
    fi
done

if [[ "${#missing[@]}" -gt 0 ]]; then
    info "installing: ${missing[*]}"
    if apt-cache show gh >/dev/null 2>&1; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${missing[@]}"
    else
        # Fallback: add GitHub's official APT repo (older distros)
        info "gh not in default apt — adding GitHub APT repository"
        sudo mkdir -p -m 755 /etc/apt/keyrings
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
        sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${missing[@]}"
    fi
fi

# ─── Shared identity setup (gh auth + SSH key + registration) ───────
bash "$HERE/scripts/setup-identity.sh"

ok "05-identity done"
