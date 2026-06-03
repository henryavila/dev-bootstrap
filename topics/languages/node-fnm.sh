#!/usr/bin/env bash
# fnm + Node LTS — works on both mac (via brew) and wsl (via apt or curl).

# WSL installs fnm to ~/.local/share/fnm (curl installer --skip-shell), which is
# NOT on the engine's per-verb subshell PATH. Make it resolvable here so the
# bare `command -v fnm` / `fnm list` below work in the post-verify subshell too.
# Harmless on mac (brew already has fnm on PATH; dir simply absent).
_ensure_fnm_path() {
    command -v fnm >/dev/null 2>&1 && return 0
    [[ -x "$HOME/.local/share/fnm/fnm" ]] && { PATH="$HOME/.local/share/fnm:$PATH"; export PATH; return 0; }
    return 1
}

check() {
    _ensure_fnm_path || return 1
    # `fnm list` only sees installed node versions after `fnm env` is evaluated.
    eval "$(fnm env 2>/dev/null || true)"
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
    _ensure_fnm_path || true
    eval "$(fnm env 2>/dev/null || true)"
    if ! fnm list 2>/dev/null | grep -qE '\bv[0-9]+\.[0-9]+\.[0-9]+'; then
        if ! fnm install --lts; then
            echo "node-fnm: 'fnm install --lts' failed — no Node version installed" >&2
            return 1
        fi
        local default_ver
        default_ver="$(fnm list | awk '/^\s*v[0-9]/ {print $NF}' | tail -1 || true)"
        [[ -n "$default_ver" ]] && fnm default "$default_ver" || true
    fi
    # Re-assert a Node version actually exists before reporting success, so a
    # silent install failure surfaces as a truthful install rc (not a post-verify rc67).
    if ! fnm list 2>/dev/null | grep -qE '\bv[0-9]+\.[0-9]+\.[0-9]+'; then
        echo "node-fnm: no Node version present after install" >&2
        return 1
    fi
}

verify() { check; }

rollback() {
    :   # don't auto-uninstall Node — user data + tools may depend on it
}
