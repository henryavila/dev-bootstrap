#!/usr/bin/env bash
# Custom installer: launch moshi-hook daemon on macOS.
#
# Two paths:
#   - canonical brew prefix (/opt/homebrew or /usr/local): brew services start
#   - custom prefix (e.g. /Volumes/External/homebrew): launch-wrapper for TCC
#
# Also handles first-time pairing + agent hook installation.

# Source log.sh defensively so info()/followup() resolve even when this script
# is sourced/run outside the engine (which pre-loads log.sh at top level).
# Mirrors moshi-hook-service-wsl.sh / install-moshi-hook.sh. log.sh is
# source-only (no side effects beyond defining functions), so re-sourcing is safe.
_MOSHI_WS_DIR="${MESH_WORKSTATION_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck disable=SC1091
. "$_MOSHI_WS_DIR/scripts/lib/log.sh"

_use_wrapper() {
    case "${BREW_PREFIX:-}" in
        /opt/homebrew|/usr/local|"") return 1 ;;
        *) return 0 ;;
    esac
}

_is_running() {
    pgrep -u "$USER" -f 'moshi-hook serve' >/dev/null 2>&1 && return 0
    if ! _use_wrapper; then
        "${BREW_BIN:-brew}" services list 2>/dev/null \
            | awk '$1=="moshi-hook"{print $2}' | grep -qx 'started' && return 0
    else
        launchctl print "gui/$(id -u)/com.${USER}.moshi-hook" 2>/dev/null \
            | grep -qE 'state[[:space:]]*=[[:space:]]*running' && return 0
    fi
    return 1
}

_is_paired() {
    [[ -f "$HOME/.config/moshi/config.json" ]] \
        && moshi-hook status 2>/dev/null | grep -qi "paired\|connected" && return 0
    return 1
}

check() {
    _is_running
}

install() {
    local ws_dir="${MESH_WORKSTATION_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

    # Teardown conflicting homebrew plists (both system + user scope)
    # before installing our wrapper — prevents dual-plist exit 78 loop.
    # shellcheck disable=SC1091
    . "$ws_dir/scripts/lib/launch-wrapper.sh"
    launch_wrapper_teardown_homebrew_plist moshi-hook 2>/dev/null || true

    if _use_wrapper; then
        local bin="${BREW_PREFIX}/opt/moshi-hook/bin/moshi-hook"
        [[ -x "$bin" ]] || { echo "[moshi-hook-service-mac] $bin not executable" >&2; return 1; }
        launch_wrapper_install_extbrew \
            --svc moshi-hook \
            --label "com.${USER}.moshi-hook" \
            --brew-bin "$bin" \
            -- serve
    else
        "${BREW_BIN:-brew}" services start moshi-hook \
            || { echo "[moshi-hook-service-mac] brew services start failed" >&2; return 1; }
    fi

    sleep 2

    # Pair if not already (one-shot, token from secrets.env)
    if ! _is_paired; then
        if [[ -n "${MOSHI_PAIRING_TOKEN:-}" ]]; then
            info "pairing moshi-hook with token from secrets.env"
            moshi-hook pair --token "$MOSHI_PAIRING_TOKEN" || true
        else
            followup manual "Run: moshi-hook pair --token <TOKEN> (from Moshi app → Settings → Integrations)"
        fi
    fi

    # Install agent hooks (idempotent)
    moshi-hook install 2>/dev/null || true
}

verify() {
    _is_running
}

rollback() {
    local ws_dir="${MESH_WORKSTATION_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
    # shellcheck disable=SC1091
    . "$ws_dir/scripts/lib/launch-wrapper.sh"
    if _use_wrapper; then
        launch_wrapper_teardown "com.${USER}.moshi-hook" 2>/dev/null || true
    else
        "${BREW_BIN:-brew}" services stop moshi-hook 2>/dev/null || true
    fi
}
