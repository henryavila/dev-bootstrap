#!/usr/bin/env bash
check() { command -v delta >/dev/null 2>&1; }

install() {
    local ver tmp
    command -v jq >/dev/null 2>&1 || { echo '[delta] jq required' >&2; return 1; }
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    ver="$(curl -fsSL "https://api.github.com/repos/dandavison/delta/releases/latest" | jq -r '.tag_name')"
    [[ -n "$ver" && "$ver" != "null" ]] || { echo '[delta] could not resolve latest release tag' >&2; return 1; }
    curl -fsSL -o "$tmp/delta.deb" \
        "https://github.com/dandavison/delta/releases/download/${ver}/git-delta_${ver}_amd64.deb"
    sudo dpkg -i "$tmp/delta.deb"
}

verify()  { check; }
rollback() {
    dpkg -s git-delta >/dev/null 2>&1 && sudo apt-get remove -y -q git-delta 2>/dev/null || true
}
