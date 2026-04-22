#!/usr/bin/env bash
# 05-identity (WSL/Linux): gh CLI + SSH key + GitHub registration.
# Runs BEFORE 95-dotfiles-personal so the private dotfiles clone works.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

# ─── Install gh CLI ─────────────────────────────────────────────────
# Ubuntu 24.04+ ships gh in the default apt repo (version 2.88+).
# Older Ubuntu (20.04/22.04) need the GitHub APT repo fallback.
if command -v gh >/dev/null 2>&1; then
    ok "gh already installed ($(gh --version | head -1))"
else
    info "installing gh CLI"
    if apt-cache show gh >/dev/null 2>&1; then
        sudo apt-get install -y -qq gh
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
        sudo apt-get install -y -qq gh
    fi
fi

# ─── Shared identity setup (gh auth + SSH key + registration) ───────
bash "$HERE/scripts/setup-identity.sh"

ok "05-identity done"
