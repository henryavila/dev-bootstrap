#!/usr/bin/env bash
# Custom installer: Tailscale.app on macOS.
#
# Detection precedence: Tailscale.app may be installed via .pkg, brew cask,
# or Mac App Store. If /Applications/Tailscale.app exists by any route,
# treat as installed.
#
# Fresh install via brew cask CAN fail on first try because the kernel
# extension needs user approval in System Settings → Privacy & Security,
# which fails silently when brew runs /usr/sbin/installer under sudo. In
# that case, instructions for the .pkg fallback are emitted.

check() {
    [[ -d /Applications/Tailscale.app ]] && return 0
    "${BREW_BIN:-brew}" list --cask tailscale >/dev/null 2>&1
}

install() {
    if [[ -d /Applications/Tailscale.app ]]; then
        return 0
    fi
    if ! "${BREW_BIN:-brew}" install --cask tailscale; then
        echo "[tailscale-mac] brew install --cask tailscale failed — likely kext approval" >&2
        echo "[tailscale-mac] fix: download the .pkg from https://tailscale.com/download/macos" >&2
        echo "[tailscale-mac]      run it locally (not via SSH) to trigger System Settings approval" >&2
        echo "[tailscale-mac]      then re-run this topic; it'll detect Tailscale.app already installed" >&2
        return 1
    fi
}

verify() {
    check
}

repair() { install; }

rollback() {
    # Don't auto-uninstall — Tailscale carries state (auth, ACL, MagicDNS).
    :
}
