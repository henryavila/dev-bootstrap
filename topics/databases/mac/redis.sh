#!/usr/bin/env bash
# Custom: Redis on macOS (brew formula + service launch).
# Uses launch-wrapper for non-canonical BREW_PREFIX (TCC sandbox workaround).

_use_wrapper() {
    case "${BREW_PREFIX:-}" in
        /opt/homebrew|/usr/local|"") return 1 ;;
        *) return 0 ;;
    esac
}

check() {
    "${BREW_BIN:-brew}" list --formula redis >/dev/null 2>&1 || return 1
    # Service running check: either brew services started, or wrapper alive, or pgrep.
    pgrep -u "$USER" -f 'redis-server' >/dev/null 2>&1 && return 0
    if _use_wrapper; then
        launchctl print "gui/$(id -u)/com.${USER}.redis" 2>/dev/null | grep -qE 'state[[:space:]]*=[[:space:]]*running'
    else
        "${BREW_BIN:-brew}" services list 2>/dev/null | awk '$1=="redis"{print $2}' | grep -qx 'started'
    fi
}

install() {
    "${BREW_BIN:-brew}" list --formula redis >/dev/null 2>&1 || "${BREW_BIN:-brew}" install redis
    if _use_wrapper; then
        # shellcheck disable=SC1091
        . "${MESH_WORKSTATION_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}/scripts/lib/launch-wrapper.sh"
        launch_wrapper_install_extbrew \
            --svc redis \
            --label "com.${USER}.redis" \
            --brew-bin "${BREW_PREFIX}/opt/redis/bin/redis-server" \
            --workdir "${BREW_PREFIX}/var" \
            -- "${BREW_PREFIX}/etc/redis.conf"
    else
        # Surface a real start failure as an install failure (clearer than a
        # post-verify rc67 whole-run abort). Stale plist / already-loaded is fine.
        "${BREW_BIN:-brew}" services start redis >/dev/null 2>&1 || return 1
    fi
}

verify() {
    # Brief readiness wait: a daemon still spawning right after `services start`
    # would be misread as failed by an immediate check(). Retry up to ~3s.
    local i
    for i in 1 2 3 4 5 6; do
        check && return 0
        sleep 0.5
    done
    check
}

rollback() {
    if _use_wrapper; then
        launchctl bootout "gui/$(id -u)/com.${USER}.redis" 2>/dev/null || true
    else
        "${BREW_BIN:-brew}" services stop redis 2>/dev/null || true
    fi
}
