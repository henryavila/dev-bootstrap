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

# True if `fnm list` shows at least one installed Node version (vX.Y.Z).
#
# IMPORTANT — do NOT rewrite this as `fnm list | grep -q ...`. The engine runs
# drivers under `set -o pipefail`. `grep -q` exits on the first match and closes
# the pipe; `fnm` is a Rust binary that IGNORES SIGPIPE, so its next write hits
# EPIPE and it PANICS (exit 101). pipefail then adopts that 101 as the pipeline's
# rc even though grep matched — an intermittent (~50%) false negative that makes
# check()/install() wrongly report "no Node version present". Capturing the
# output into a variable reads stdout to EOF (no early close → no panic → no
# race). `=~` uses ERE and must NOT contain `\b` (bash 3.2 reads `\b` as a
# literal backspace, so it would never match).
_fnm_has_node() {
    local _v; _v="$(fnm list 2>/dev/null)"
    [[ "$_v" =~ v[0-9]+\.[0-9]+\.[0-9]+ ]]
}

check() {
    _ensure_fnm_path || return 1
    # `fnm list` only sees installed node versions after `fnm env` is evaluated.
    eval "$(fnm env 2>/dev/null || true)"
    _fnm_has_node
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
    if ! _fnm_has_node; then
        if ! fnm install --lts; then
            echo "node-fnm: 'fnm install --lts' failed — no Node version installed" >&2
            return 1
        fi
        # Set the just-installed (highest) version as the default. Capture the
        # list once and extract the version with sed BRE: the old
        # `awk '/^\s*v[0-9]/ {print $NF}'` never matched (fnm rows start with
        # `* `, not whitespace+v, and $NF is the alias, not the version), so the
        # default was silently never set; BSD awk also lacks `\s`.
        local _list default_ver
        _list="$(fnm list 2>/dev/null)"
        default_ver="$(printf '%s\n' "$_list" \
            | sed -n 's/.*\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | tail -1)"
        [[ -n "$default_ver" ]] && fnm default "$default_ver" || true
    fi
    # Re-assert a Node version actually exists before reporting success, so a
    # silent install failure surfaces as a truthful install rc (not a post-verify rc67).
    if ! _fnm_has_node; then
        echo "node-fnm: no Node version present after install" >&2
        return 1
    fi
}

verify() { check; }

rollback() {
    :   # don't auto-uninstall Node — user data + tools may depend on it
}
