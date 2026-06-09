#!/usr/bin/env bash
# scripts/lib/conditions.sh — named `when:` conditions for manifest.yaml v2.
#
# Sourced by the install/uninstall engine to resolve an item's `when: <name>`
# gate (spec §3.1). Each condition is a `cond_<name>()` function returning
# 0 (true → run the item) or 1 (false → skip silently).
#
# The inline option form `when: option.<toggle>` is NOT handled here — the
# engine resolves it directly against the bundle's resolved option env vars.
# This file owns only the NAMED conditions.
#
# Public API:
#   cond_eval <name>     → run cond_<name>; rc 0/1; rc 2 if <name> is unknown
#   cond_is_known <name> → rc 0 if <name> is a defined named condition
#   cond_list            → echo every known condition name, one per line
#                          (validate-manifest.sh uses this for §8 rule 13)
#
# Bash 3.2 floor (engine runs under /bin/bash on macOS). Sourced, not executed:
# no top-level `set -e` (would leak into the caller).
#
# Test hooks (override detection without a real environment):
#   MESH_COND_OS=mac|wsl|linux   force the OS verdict
#   MESH_WSL_CORPORATE=1         force wsl_corporate true

[ -n "${_CONDITIONS_LOADED:-}" ] && return 0
_CONDITIONS_LOADED=1

_COND_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# install-state markers back the php_installed check.
# shellcheck source=/dev/null
. "$_COND_LIB_DIR/install-state.sh"

# --- detection helpers -------------------------------------------------------

# Cached OS verdict: mac | wsl | linux | unknown (honors MESH_COND_OS test hook).
_cond_os() {
    if [ -n "${MESH_COND_OS:-}" ]; then printf '%s' "$MESH_COND_OS"; return 0; fi
    if [ -z "${_COND_OS:-}" ]; then
        case "$(uname -s)" in
            Darwin) _COND_OS=mac ;;
            Linux)  if grep -qi microsoft /proc/version 2>/dev/null; then _COND_OS=wsl; else _COND_OS=linux; fi ;;
            *)      _COND_OS=unknown ;;
        esac
    fi
    printf '%s' "$_COND_OS"
}

# Echo the Homebrew prefix via detect-brew.sh, or nothing if brew is absent.
_cond_brew_prefix() {
    local out
    out="$(bash "$_COND_LIB_DIR/detect-brew.sh" 2>/dev/null)" || return 1
    # detect-brew.sh emits `BREW_BIN=...` + `BREW_PREFIX=...` (printf %q, eval-safe).
    eval "$out"
    [ -n "${BREW_PREFIX:-}" ] || return 1
    printf '%s' "$BREW_PREFIX"
}

# Numeric owner uid of a path (Mac `stat -f`, Linux `stat -c`).
_cond_owner_uid() {
    stat -f '%u' "$1" 2>/dev/null || stat -c '%u' "$1" 2>/dev/null
}

# --- conditions --------------------------------------------------------------

# Mac with a Homebrew prefix that is neither /opt/homebrew nor /usr/local
# (e.g. an external-disk install). Gates mac items that need a path fix-up.
cond_brew_prefix_custom() {
    [ "$(_cond_os)" = mac ] || return 1
    local prefix
    prefix="$(_cond_brew_prefix)" || return 1
    case "$prefix" in
        /opt/homebrew|/usr/local) return 1 ;;
        *) return 0 ;;
    esac
}

# WSL behind a corporate cert chain. Explicit opt-in is authoritative; the
# cert-store heuristic is best-effort (no item ships using this yet).
cond_wsl_corporate() {
    [ "$(_cond_os)" = wsl ] || return 1
    case "${MESH_WSL_CORPORATE:-}" in 1|true|yes|on) return 0 ;; esac
    ls /usr/local/share/ca-certificates/*.crt >/dev/null 2>&1
}

# WSL with `systemd=true` in /etc/wsl.conf (user services need it).
cond_wsl_systemd() {
    [ "$(_cond_os)" = wsl ] || return 1
    [ -f /etc/wsl.conf ] || return 1
    grep -qiE '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true' /etc/wsl.conf 2>/dev/null
}

# A Tailscale auth key is available for non-interactive `tailscale up`.
# The engine sources secrets.env before evaluating when:, so the env var is
# the single signal here.
cond_tailscale_authkey_present() {
    [ -n "${TAILSCALE_AUTHKEY:-}" ]
}

# A PHP toolchain mesh can build extensions against. Canonical signal is the
# languages/php install-state marker (spec §3.1); a php on PATH is accepted as
# a fallback so foreign / pre-mesh PHP also satisfies the gate.
cond_php_installed() {
    local t n
    for t in languages 10-languages; do
        for n in php-stack php-stack-mac php-stack-wsl php; do
            if install_state_has "$t" "$n" 2>/dev/null; then return 0; fi
        done
    done
    command -v php >/dev/null 2>&1
}

# Homebrew prefix owned by root → privileged ops need sudo.
cond_is_root_owned_brew() {
    local prefix owner
    prefix="$(_cond_brew_prefix)" || return 1
    owner="$(_cond_owner_uid "$prefix")" || return 1
    [ "$owner" = 0 ]
}

# --- dispatcher / introspection ----------------------------------------------

cond_is_known() {
    case "$1" in
        brew_prefix_custom|wsl_corporate|wsl_systemd|tailscale_authkey_present|php_installed|is_root_owned_brew)
            return 0 ;;
        *) return 1 ;;
    esac
}

cond_list() {
    printf '%s\n' \
        brew_prefix_custom \
        wsl_corporate \
        wsl_systemd \
        tailscale_authkey_present \
        php_installed \
        is_root_owned_brew
}

cond_eval() {
    local name="${1:-}"
    if ! cond_is_known "$name"; then
        printf 'conditions: unknown condition "%s"\n' "$name" >&2
        return 2
    fi
    "cond_$name"
}
