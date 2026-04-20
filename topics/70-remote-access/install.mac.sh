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

# Tailscale (cask — .app com GUI e daemon próprio)
if "$BREW_BIN" list --cask tailscale >/dev/null 2>&1; then
    ok "tailscale already installed"
else
    info "brew install --cask tailscale"
    "$BREW_BIN" install --cask tailscale
fi

ok "70-remote-access (mac) done"
warn "launch Tailscale.app once to authenticate"

# ---------- Tailscale MTU fix: NÃO automatizado no Mac ----------
# Tailscale.app gerencia o daemon próprio (não é systemd nem launchd direto).
# A interface utun<N> varia a cada sessão. Setar MTU via ifconfig funciona
# em runtime mas não persiste — para persistir precisa LaunchDaemon custom.
#
# Se experimentar SSH travando em KEX via Tailscale (OpenSSH 9.6+), rodar:
#   sudo bash $HERE/scripts/mac-tailscale-mtu-fix.sh
#
# Ver README.md seção "Tailscale MTU gotcha".
info "Tailscale MTU fix no Mac: rodar 'sudo bash topics/70-remote-access/scripts/mac-tailscale-mtu-fix.sh' on-demand"
info "(ver README.md seção 'Tailscale MTU gotcha' se SSH travar via Tailscale)"
