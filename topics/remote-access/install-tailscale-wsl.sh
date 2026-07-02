#!/usr/bin/env bash
# Custom installer: Tailscale on WSL via curl-pipe install script.

check() {
    command -v tailscale >/dev/null 2>&1
}

install() {
    # Capture the installer first so a curl failure (network/DNS/4xx) becomes the
    # install rc — piping straight into `sh` masks it (sh exits 0 on empty stdin).
    local tmp
    tmp="$(mktemp)" || return 1
    curl -fsSL https://tailscale.com/install.sh -o "$tmp" || { rm -f "$tmp"; return 1; }
    sh "$tmp"
    local rc=$?
    rm -f "$tmp"
    return $rc
}

verify() {
    check
}

repair() { install; }

rollback() {
    # Don't auto-uninstall — Tailscale carries state.
    :
}
