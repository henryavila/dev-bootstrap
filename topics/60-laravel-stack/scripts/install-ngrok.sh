#!/usr/bin/env bash
# install-ngrok.sh — ngrok agent for tunneling local sites publicly.
# Gated by INCLUDE_NGROK=1.
#
# The companion CLI `share-project` (deployed via link-project templates)
# is a thin wrapper around `ngrok http`.
#
# Authtoken: not configured automatically (free tier still needs a
# signup). Set NGROK_AUTHTOKEN=... before running this script to
# auto-configure, or run `ngrok config add-authtoken <token>` later.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../../lib/log.sh"

OS=""
case "$(uname -s)" in
    Darwin) OS="mac" ;;
    Linux)  OS="linux" ;;  # same apt path works for WSL and native Linux
    *)      fail "unsupported OS"; exit 1 ;;
esac

if command -v ngrok >/dev/null 2>&1; then
    ok "ngrok already installed ($(ngrok --version 2>/dev/null | head -1 || echo '?'))"
else
    case "$OS" in
        mac)
            : "${BREW_BIN:?BREW_BIN not set}"
            info "brew install ngrok"
            "$BREW_BIN" install --cask ngrok
            ;;
        linux)
            info "adding ngrok APT source"
            sudo install -d -m 0755 /etc/apt/keyrings
            curl -sSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
                | sudo tee /etc/apt/keyrings/ngrok.asc > /dev/null
            echo "deb [signed-by=/etc/apt/keyrings/ngrok.asc] https://ngrok-agent.s3.amazonaws.com buster main" \
                | sudo tee /etc/apt/sources.list.d/ngrok.list > /dev/null
            sudo apt-get update -qq
            sudo apt-get install -y -qq ngrok
            ;;
    esac
    ok "ngrok installed"
fi

# ─── Authtoken (optional) ────────────────────────────────────────────
if [[ -n "${NGROK_AUTHTOKEN:-}" ]]; then
    info "configuring ngrok authtoken from NGROK_AUTHTOKEN env"
    ngrok config add-authtoken "$NGROK_AUTHTOKEN" >/dev/null
    ok "ngrok authtoken set"
elif ! ngrok config check >/dev/null 2>&1; then
    warn "ngrok installed but no authtoken configured."
    warn "  1. sign up at https://ngrok.com (free tier works)"
    warn "  2. copy your token from https://dashboard.ngrok.com/get-started/your-authtoken"
    warn "  3. run: ngrok config add-authtoken <token>"
    warn "  OR re-run bootstrap with NGROK_AUTHTOKEN=<token> to auto-configure."
else
    ok "ngrok authtoken already configured"
fi

ok "ngrok ready — use \`share-project <name>\` to tunnel a site"
