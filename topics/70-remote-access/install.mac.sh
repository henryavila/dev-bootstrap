#!/usr/bin/env bash
# 70-remote-access (mac): enable Remote Login, Tailscale, mosh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

: "${BREW_BIN:?BREW_BIN not set}"

# Remote Login (sshd)
if sudo systemsetup -getremotelogin 2>/dev/null | grep -qi 'on'; then
    ok "Remote Login already enabled"
else
    info "enabling Remote Login (sshd)"
    sudo systemsetup -setremotelogin on
fi

# mosh
if "$BREW_BIN" list --formula mosh >/dev/null 2>&1; then
    ok "mosh already installed"
else
    info "brew install mosh"
    "$BREW_BIN" install mosh
fi

# Tailscale (cask)
if "$BREW_BIN" list --cask tailscale >/dev/null 2>&1; then
    ok "tailscale already installed"
else
    info "brew install --cask tailscale"
    "$BREW_BIN" install --cask tailscale
fi

ok "70-remote-access (mac) done"
warn "launch Tailscale.app once to authenticate"
