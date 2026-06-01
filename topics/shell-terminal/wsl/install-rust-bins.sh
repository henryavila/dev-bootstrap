#!/usr/bin/env bash
# dust + xh + procs — single-file Rust binaries not in apt 24.04.
# Installed to ~/.local/bin via GitHub release tarballs. Idempotent.

_install_dust() {
    local ver tmp
    ver="$(curl -fsSL "https://api.github.com/repos/bootandy/dust/releases/latest" | jq -r '.tag_name')"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/dust.tgz" \
        "https://github.com/bootandy/dust/releases/download/${ver}/dust-${ver}-x86_64-unknown-linux-gnu.tar.gz"
    tar -C "$tmp" -xzf "$tmp/dust.tgz" --strip-components=1
    install -m 0755 "$tmp/dust" "$HOME/.local/bin/dust"
    rm -rf "$tmp"
}

_install_xh() {
    local ver tmp
    ver="$(curl -fsSL "https://api.github.com/repos/ducaale/xh/releases/latest" | jq -r '.tag_name')"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/xh.tgz" \
        "https://github.com/ducaale/xh/releases/download/${ver}/xh-${ver}-x86_64-unknown-linux-musl.tar.gz"
    tar -C "$tmp" -xzf "$tmp/xh.tgz" --strip-components=1
    install -m 0755 "$tmp/xh" "$HOME/.local/bin/xh"
    rm -rf "$tmp"
}

_install_procs() {
    local ver tmp
    ver="$(curl -fsSL "https://api.github.com/repos/dalance/procs/releases/latest" | jq -r '.tag_name')"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/procs.zip" \
        "https://github.com/dalance/procs/releases/download/${ver}/procs-${ver}-x86_64-linux.zip"
    unzip -q -o "$tmp/procs.zip" -d "$tmp"
    install -m 0755 "$tmp/procs" "$HOME/.local/bin/procs"
    rm -rf "$tmp"
}

check() {
    command -v dust  >/dev/null 2>&1 \
        && command -v xh    >/dev/null 2>&1 \
        && command -v procs >/dev/null 2>&1
}

install() {
    mkdir -p "$HOME/.local/bin"
    command -v dust  >/dev/null 2>&1 || _install_dust
    command -v xh    >/dev/null 2>&1 || _install_xh
    command -v procs >/dev/null 2>&1 || _install_procs
}

verify() { check; }

rollback() {
    local b
    for b in dust xh procs; do
        [[ -x "$HOME/.local/bin/$b" ]] && rm -f "$HOME/.local/bin/$b"
    done
}
