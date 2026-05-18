#!/usr/bin/env bash
# Custom installer: Tailscale on WSL via curl-pipe install script.

check() {
    command -v tailscale >/dev/null 2>&1
}

install() {
    curl -fsSL https://tailscale.com/install.sh | sh
}

verify() {
    check
}

rollback() {
    # Don't auto-uninstall — Tailscale carries state.
    :
}
