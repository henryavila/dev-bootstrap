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
        # Capture then bash-match — NOT `launchctl print | grep -q`: launchctl
        # dies on SIGPIPE (141) when grep -q closes the pipe early, and under the
        # engine's pipefail that 141 becomes a false "not running". See
        # feedback_engine_pipefail_grep_q_broken_pipe (lint L21).
        local _lc; _lc="$(launchctl print "gui/$(id -u)/com.${USER}.redis" 2>/dev/null)"
        [[ "$_lc" =~ state[[:space:]]*=[[:space:]]*running ]]
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
    for _ in 1 2 3 4 5 6; do
        check && return 0
        sleep 0.5
    done
    check
}

repair() { install; }

rollback() {
    if _use_wrapper; then
        launchctl bootout "gui/$(id -u)/com.${USER}.redis" 2>/dev/null || true
    else
        "${BREW_BIN:-brew}" services stop redis 2>/dev/null || true
    fi
}

uninstall() {
    # Reverse install(): stop the service the way install() started it, then
    # remove the brew *formula* (install used `brew install redis`, a formula —
    # not a cask). errexit is OFF in custom verbs: never `set +e` (L03); capture
    # rc with `cmd || rc=$?` and guard every step so re-runs are safe.
    local brew="${BREW_BIN:-brew}"

    # 1) Stop + tear down the service. Wrapper path mirrors rollback() but goes
    #    further than `launchctl bootout`: launch_wrapper_teardown also removes
    #    the generated plist + wrapper script (the full reverse of
    #    launch_wrapper_install_extbrew). Non-wrapper path stops the brew service
    #    so `brew uninstall` isn't fighting a live daemon.
    if _use_wrapper; then
        # shellcheck disable=SC1091
        . "${MESH_WORKSTATION_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}/scripts/lib/launch-wrapper.sh"
        launch_wrapper_teardown "com.${USER}.redis" 2>/dev/null || true
    else
        command -v "$brew" >/dev/null 2>&1 && "$brew" services stop redis >/dev/null 2>&1 || true
    fi

    # 2) Remove the formula. Guard on it being present so this is idempotent when
    #    redis is already gone. `--ignore-dependencies` matches the engine's own
    #    brew-formula handler: it removes *only* redis, never cascading into a
    #    shared dependency (e.g. openssl) that another bundle may rely on.
    if command -v "$brew" >/dev/null 2>&1 && "$brew" list --formula redis >/dev/null 2>&1; then
        "$brew" uninstall --ignore-dependencies redis >/dev/null 2>&1 || true
    fi

    # 3) Honest marker drop (like ngrok): succeed only when the formula is
    #    actually gone. If brew is unavailable we can't have removed it, so the
    #    list check fails and we return non-zero — the engine keeps the marker.
    if command -v "$brew" >/dev/null 2>&1; then
        ! "$brew" list --formula redis >/dev/null 2>&1
    else
        return 1
    fi
}
