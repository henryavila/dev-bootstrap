#!/usr/bin/env bash
# dust + xh + procs — single-file Rust binaries not in apt 24.04.
# Installed to ~/.local/bin via GitHub release tarballs. Idempotent.

_install_dust() {
    local ver tmp
    ver="$(curl -fsSL "https://api.github.com/repos/bootandy/dust/releases/latest" | jq -r '.tag_name')"
    [[ -n "$ver" && "$ver" != "null" ]] || return 1
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/dust.tgz" \
        "https://github.com/bootandy/dust/releases/download/${ver}/dust-${ver}-x86_64-unknown-linux-gnu.tar.gz" \
        || { rm -rf "$tmp"; return 1; }
    tar -C "$tmp" -xzf "$tmp/dust.tgz" --strip-components=1 || { rm -rf "$tmp"; return 1; }
    install -m 0755 "$tmp/dust" "$HOME/.local/bin/dust" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    [[ -x "$HOME/.local/bin/dust" ]]
}

_install_xh() {
    local ver tmp
    ver="$(curl -fsSL "https://api.github.com/repos/ducaale/xh/releases/latest" | jq -r '.tag_name')"
    [[ -n "$ver" && "$ver" != "null" ]] || return 1
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/xh.tgz" \
        "https://github.com/ducaale/xh/releases/download/${ver}/xh-${ver}-x86_64-unknown-linux-musl.tar.gz" \
        || { rm -rf "$tmp"; return 1; }
    tar -C "$tmp" -xzf "$tmp/xh.tgz" --strip-components=1 || { rm -rf "$tmp"; return 1; }
    install -m 0755 "$tmp/xh" "$HOME/.local/bin/xh" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    [[ -x "$HOME/.local/bin/xh" ]]
}

_install_procs() {
    local ver tmp
    ver="$(curl -fsSL "https://api.github.com/repos/dalance/procs/releases/latest" | jq -r '.tag_name')"
    [[ -n "$ver" && "$ver" != "null" ]] || return 1
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/procs.zip" \
        "https://github.com/dalance/procs/releases/download/${ver}/procs-${ver}-x86_64-linux.zip" \
        || { rm -rf "$tmp"; return 1; }
    unzip -q -o "$tmp/procs.zip" -d "$tmp" || { rm -rf "$tmp"; return 1; }
    install -m 0755 "$tmp/procs" "$HOME/.local/bin/procs" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    [[ -x "$HOME/.local/bin/procs" ]]
}

# Verify by absolute path: install targets ~/.local/bin, which is not on the
# engine item-subshell PATH on WSL, so a bare `command -v` would fail post-verify
# even after a correct install (mirrors rollback() below).
check() {
    ( command -v dust  >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/dust" ]] ) \
        && ( command -v xh    >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/xh" ]] ) \
        && ( command -v procs >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/procs" ]] )
}

install() {
    mkdir -p "$HOME/.local/bin"
    PATH="$HOME/.local/bin:$PATH"
    # Aggregate each helper's rc. install()'s return code is otherwise just its
    # LAST statement, so a dust/xh failure is masked when procs succeeds →
    # install() returns 0, then post-verify check() fails (binary missing) and
    # the engine exit-67's the WHOLE run instead of reporting a clean per-item
    # install failure. Flag any failure and return it.
    local _rc=0
    command -v dust  >/dev/null 2>&1 || _install_dust  || _rc=1
    command -v xh    >/dev/null 2>&1 || _install_xh    || _rc=1
    command -v procs >/dev/null 2>&1 || _install_procs || _rc=1
    return "$_rc"
}

verify() { check; }

rollback() {
    local b
    for b in dust xh procs; do
        [[ -x "$HOME/.local/bin/$b" ]] && rm -f "$HOME/.local/bin/$b"
    done
}
