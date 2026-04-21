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

# Tailscale (cask — .app with GUI and its own daemon)
#
# Detection precedence: Tailscale.app can be installed 3 ways on Mac —
#   1. Directly via .pkg download (bypasses brew; required on first-time
#      install because the kernel extension needs user approval in
#      System Settings → Privacy & Security, which fails silently when
#      brew runs /usr/sbin/installer under sudo).
#   2. Via `brew install --cask tailscale` (works ONLY if the kext was
#      already approved via a prior .pkg install).
#   3. From the Mac App Store (sandboxed version — less common).
#
# If /Applications/Tailscale.app exists by any route, treat it as installed.
# Otherwise, attempt brew cask but expect potential failure on a fresh Mac.
if [[ -d "/Applications/Tailscale.app" ]]; then
    ok "Tailscale.app already installed (via brew, .pkg, or App Store)"
elif "$BREW_BIN" list --cask tailscale >/dev/null 2>&1; then
    ok "tailscale already installed (brew cask)"
else
    info "brew install --cask tailscale"
    if ! "$BREW_BIN" install --cask tailscale; then
        warn "brew install --cask tailscale failed — likely the kernel extension approval"
        warn "fix: download the .pkg from https://tailscale.com/download/macos"
        warn "     run it locally (not via SSH) to trigger the System Settings approval dialog"
        warn "     after that, 'brew install --cask tailscale' or simply launching Tailscale.app works"
        warn "     (this topic will pass on next bootstrap run once Tailscale.app exists in /Applications)"
        exit 1
    fi
fi

ok "70-remote-access (mac) done"
warn "launch Tailscale.app once to authenticate"

# ---------- Tailscale MTU fix: NOT automated on Mac ----------
# Tailscale.app runs its own daemon (neither systemd nor a standalone
# launchd job). The utun<N> interface number varies per session. Setting
# MTU via ifconfig works at runtime but doesn't persist — to persist you'd
# need a custom LaunchDaemon.
#
# If SSH hangs in KEX via Tailscale (OpenSSH 9.6+), run:
#   sudo bash $HERE/scripts/mac-tailscale-mtu-fix.sh
#
# See README.md section "Tailscale MTU gotcha".
info "Tailscale MTU fix on Mac: run 'sudo bash topics/70-remote-access/scripts/mac-tailscale-mtu-fix.sh' on-demand"
info "(see README.md section 'Tailscale MTU gotcha' if SSH hangs via Tailscale)"
