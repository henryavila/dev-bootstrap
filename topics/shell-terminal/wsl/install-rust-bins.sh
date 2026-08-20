#!/usr/bin/env bash
# shellcheck source=/dev/null
. "${MESH_WORKSTATION_DIR:-$HOME/mesh-workstation}/scripts/lib/github-api.sh"
# dust + xh + procs — single-file Rust binaries not in apt 24.04.
# Installed to ~/.local/bin via GitHub release tarballs. Idempotent.
#
# Marked soft_fail in the manifest: a CDN stall must not abort bootstrap.
#
# Fail-fast (CRC hang root cause): nested gh_api retries × curl --retry ×
# three binaries looked like an endless "resolving/downloading dust tag"
# loop on corporate networks. One shot per binary, no curl retries, short
# API budget, and a circuit breaker that refuses a second attempt.

# Single attempt — no --retry / --retry-all-errors (those re-entered the
# resolve/download cycle under flaky proxies and burned the soft_fail budget).
_RB_CURL=(curl -fsSL --connect-timeout 8 --max-time 45)
# Cap GitHub API attempts for this installer (honoured by github-api.sh).
: "${MESH_GH_API_ATTEMPTS:=2}"
export MESH_GH_API_ATTEMPTS

_rb_log() { printf '[rust-bins-wsl] %s\n' "$*" >&2; }

# Circuit breaker: each binary is attempted at most once per install()/repair()
# invocation. A second call logs and returns 1 immediately (no re-resolve).
_rb_guard() {
    local name="$1"
    local var="_RB_TRIED_${name}"
    if [[ "${!var:-0}" -ge 1 ]]; then
        _rb_log "circuit breaker: ${name} already attempted — refusing loop"
        return 1
    fi
    printf -v "$var" '%s' 1
    return 0
}

_install_dust() {
    _rb_guard dust || return 1
    local ver tmp
    _rb_log "resolving latest dust release tag"
    ver="$(gh_latest_tag bootandy/dust)"
    [[ -n "$ver" && "$ver" != "null" ]] || { _rb_log "dust: could not resolve tag"; return 1; }
    tmp="$(mktemp -d)"
    _rb_log "downloading dust ${ver} (one-shot)"
    if ! "${_RB_CURL[@]}" -o "$tmp/dust.tgz" \
        "https://github.com/bootandy/dust/releases/download/${ver}/dust-${ver}-x86_64-unknown-linux-gnu.tar.gz"
    then
        _rb_log "dust: download failed"
        rm -rf "$tmp"
        return 1
    fi
    tar -C "$tmp" -xzf "$tmp/dust.tgz" --strip-components=1 || { rm -rf "$tmp"; return 1; }
    install -m 0755 "$tmp/dust" "$HOME/.local/bin/dust" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    [[ -x "$HOME/.local/bin/dust" ]]
}

_install_xh() {
    _rb_guard xh || return 1
    local ver tmp
    _rb_log "resolving latest xh release tag"
    ver="$(gh_latest_tag ducaale/xh)"
    [[ -n "$ver" && "$ver" != "null" ]] || { _rb_log "xh: could not resolve tag"; return 1; }
    tmp="$(mktemp -d)"
    _rb_log "downloading xh ${ver} (one-shot)"
    if ! "${_RB_CURL[@]}" -o "$tmp/xh.tgz" \
        "https://github.com/ducaale/xh/releases/download/${ver}/xh-${ver}-x86_64-unknown-linux-musl.tar.gz"
    then
        _rb_log "xh: download failed"
        rm -rf "$tmp"
        return 1
    fi
    tar -C "$tmp" -xzf "$tmp/xh.tgz" --strip-components=1 || { rm -rf "$tmp"; return 1; }
    install -m 0755 "$tmp/xh" "$HOME/.local/bin/xh" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    [[ -x "$HOME/.local/bin/xh" ]]
}

_install_procs() {
    _rb_guard procs || return 1
    local ver tmp
    _rb_log "resolving latest procs release tag"
    ver="$(gh_latest_tag dalance/procs)"
    [[ -n "$ver" && "$ver" != "null" ]] || { _rb_log "procs: could not resolve tag"; return 1; }
    tmp="$(mktemp -d)"
    _rb_log "downloading procs ${ver} (one-shot)"
    if ! "${_RB_CURL[@]}" -o "$tmp/procs.zip" \
        "https://github.com/dalance/procs/releases/download/${ver}/procs-${ver}-x86_64-linux.zip"
    then
        _rb_log "procs: download failed"
        rm -rf "$tmp"
        return 1
    fi
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
    # One pass only. On first binary failure keep going once for the others so
    # a single CDN blip does not skip siblings — but each binary is guarded
    # against re-entry (circuit breaker). Never retry a failed binary here;
    # soft_fail on the item is the recovery path for the whole bootstrap.
    local _rc=0
    if ! command -v dust  >/dev/null 2>&1; then
        _install_dust  || { _rb_log "dust install failed — not retrying"; _rc=1; }
    fi
    if ! command -v xh    >/dev/null 2>&1; then
        _install_xh    || { _rb_log "xh install failed — not retrying"; _rc=1; }
    fi
    if ! command -v procs >/dev/null 2>&1; then
        _install_procs || { _rb_log "procs install failed — not retrying"; _rc=1; }
    fi
    return "$_rc"
}

verify() { check; }

repair() {
    # Fresh attempt window for doctor --fix / repair sweeps.
    _RB_TRIED_dust=0
    _RB_TRIED_xh=0
    _RB_TRIED_procs=0
    install
}

rollback() {
    local b
    for b in dust xh procs; do
        [[ -x "$HOME/.local/bin/$b" ]] && rm -f "$HOME/.local/bin/$b"
    done
}
