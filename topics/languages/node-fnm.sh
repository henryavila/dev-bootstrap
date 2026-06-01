#!/usr/bin/env bash
# fnm + Node LTS — works on both mac (via brew) and wsl (via apt or curl).

check() {
    command -v fnm >/dev/null 2>&1 || return 1
    fnm list 2>/dev/null | grep -qE '\bv[0-9]+\.[0-9]+\.[0-9]+'
}

install() {
    if ! command -v fnm >/dev/null 2>&1; then
        if [[ "$(uname -s)" == "Darwin" ]]; then
            "${BREW_BIN:-brew}" install fnm
        else
            # WSL/Linux: official installer
            curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
            PATH="$HOME/.local/share/fnm:$PATH"; export PATH
        fi
    fi
    eval "$(fnm env 2>/dev/null || true)"
    if ! fnm list 2>/dev/null | grep -qE '\bv[0-9]+\.[0-9]+\.[0-9]+'; then
        fnm install --lts
        local default_ver
        default_ver="$(fnm list | awk '/^\s*v[0-9]/ {print $NF}' | tail -1 || true)"
        [[ -n "$default_ver" ]] && fnm default "$default_ver" || true
    fi
}

verify() { check; }

rollback() {
    :   # don't auto-uninstall Node — user data + tools may depend on it
}
