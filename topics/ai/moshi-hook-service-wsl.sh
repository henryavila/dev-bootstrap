#!/usr/bin/env bash
# Custom installer: moshi-hook daemon on Linux/WSL.
# Uses user-service.sh lib (systemd user service with nohup fallback).
# Also handles first-time pairing + agent hook installation.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_DIR="${MESH_WORKSTATION_DIR:-$(cd "$HERE/../.." && pwd)}"
# shellcheck disable=SC1091
source "$WS_DIR/scripts/lib/log.sh"
# shellcheck disable=SC1091
source "$WS_DIR/scripts/lib/user-service.sh"

# Functional state gate (sudo-free). install() runs `enable --now`, so the
# state it actually guarantees is: systemd user unit loaded + enabled + active.
# We therefore assert is-enabled AND is-active (not just is-active) — and on the
# nohup fallback anchor pgrep on the exact `moshi-hook serve` exec install() uses,
# not a bare `moshi-hook` substring that an editor/tail/log tail would satisfy.
# We deliberately do NOT assert paired here: pairing is token-optional (install()
# falls back to a manual followup), so a running-but-unpaired daemon is a healthy
# install — asserting paired would false-fail it and trigger spurious repairs.
# Mirrors moshi-hook-service-mac.sh `_is_running`.
_is_running() {
    if user_service_has_systemd; then
        systemctl --user is-enabled moshi-hook.service >/dev/null 2>&1 || return 1
        systemctl --user is-active  moshi-hook.service >/dev/null 2>&1 || return 1
        return 0
    fi
    pgrep -u "$USER" -f 'moshi-hook serve' >/dev/null 2>&1
}

check() {
    _is_running
}

install() {
    # Resolve moshi-hook by absolute path: it installs to ~/.local/bin (not on
    # the engine item-subshell PATH on a fresh bootstrap). An empty --exec would
    # make user_service_install return 1, which aborts install() under set -e.
    local bin
    bin="$(command -v moshi-hook || true)"
    [ -n "$bin" ] || bin="$HOME/.local/bin/moshi-hook"
    [ -x "$bin" ] || { echo "moshi-hook not found (expected $bin)" >&2; return 1; }

    user_service_install \
        --name moshi-hook \
        --exec "$bin" \
        --args "serve" \
        --description "Moshi Hook — AI agent bridge daemon"

    sleep 2

    if ! "$bin" status 2>/dev/null | grep -qi "paired\|connected"; then
        if [[ -n "${MOSHI_PAIRING_TOKEN:-}" ]]; then
            info "pairing moshi-hook with token from secrets.env"
            "$bin" pair --token "$MOSHI_PAIRING_TOKEN" || true
        else
            followup manual "Run: moshi-hook pair --token <TOKEN> (from Moshi app → Settings → Integrations)"
        fi
    fi

    "$bin" install 2>/dev/null || true
}

verify() {
    # At least as strong as check(): the post-install / --repair gate must not
    # be looser than the keep/skip gate (was a bare `moshi-hook` substring pgrep).
    _is_running
}

rollback() {
    user_service_teardown moshi-hook
}

# restart() — bounce the daemon so it reloads a freshly-upgraded binary.
# Invoked by the engine's --update pass when the moshi-hook binary actually
# changed (manifest restart_service: moshi-hook-wsl-service). Gated on
# _is_running: a daemon the user deliberately stopped is left down (autoupdate
# must not resurrect it). systemd path = an in-place `restart`; the nohup
# fallback has no supervisor to reload, so teardown + re-launch via install().
restart() {
    if ! _is_running; then
        info "moshi-hook service not running — skip restart (autoupdate)"
        return 0
    fi
    if user_service_has_systemd; then
        info "restarting moshi-hook (systemd --user) to load the upgraded binary"
        systemctl --user restart moshi-hook.service || return 1
    else
        info "restarting moshi-hook (nohup fallback) to load the upgraded binary"
        rollback
        install
    fi
    sleep 1
    _is_running
}

uninstall() {
    # Reverse install() — and ONLY what install() established here. The
    # moshi-hook *binary* is owned by a separate bundle item (moshi-hook-linux
    # / install-moshi-hook.sh), whose own uninstall() removes ~/.local/bin so
    # we never touch it. This item reverses two pieces of state:
    #   1. the systemd user service (unit + enable, or the nohup fallback proc)
    #   2. the agent hook configs written by `moshi-hook install`
    # The local Moshi pairing (`moshi-hook pair`, ~/.config/moshi) is user-owned
    # account credential state and is deliberately NOT reversed here (anti-M2);
    # install() only pairs when MOSHI_PAIRING_TOKEN is set. Matches the mac sibling.
    #
    # errexit is OFF inside custom verbs and L03 bans `set +e`, so every step is
    # guarded (command -v / || true) and we capture rc explicitly where it gates
    # the result. Idempotent: each step is a no-op when the thing is already gone.

    # 1. Service teardown (same primitive as rollback(): disable+rm unit, or
    #    pkill on the nohup fallback). This is the authoritative state we gate on.
    user_service_teardown moshi-hook || true

    # 2. Reverse the agent-hook install, best-effort. Runs through the binary,
    #    which may already be gone if moshi-hook-linux uninstalled first (deselect
    #    order is not guaranteed) — hence the guard. Resolve by absolute path like
    #    install() does (~/.local/bin is not on the item-subshell PATH on a fresh
    #    bootstrap).
    local bin
    bin="$(command -v moshi-hook 2>/dev/null || true)"
    [ -n "$bin" ] || bin="$HOME/.local/bin/moshi-hook"
    if [ -x "$bin" ]; then
        # `moshi-hook uninstall` removes the agent hook configuration written by
        # `install`. We deliberately do NOT run `moshi-hook unpair`: pairing is
        # user-owned account credential state (~/.config/moshi), only created when
        # the MOSHI_PAIRING_TOKEN secret was present — tooling must never delete
        # user-owned $HOME state (anti-M2). Matches the mac sibling.
        "$bin" uninstall >/dev/null 2>&1 || true
    fi

    # Honest marker drop: success = the service install() established is actually
    # gone. Assert the systemd unit is no longer enabled/active (or, on the nohup
    # fallback, that no `moshi-hook serve` process remains for this user). Mirror
    # _is_running's probe and invert it, so the engine only clears the marker when
    # the daemon this item owns is truly down.
    if user_service_has_systemd; then
        local enrc=0
        systemctl --user is-enabled moshi-hook.service >/dev/null 2>&1 || enrc=$?
        local acrc=0
        systemctl --user is-active  moshi-hook.service >/dev/null 2>&1 || acrc=$?
        # Down = both probes failed (non-zero). If either still reports the unit,
        # teardown did not take — keep the marker by returning non-zero.
        [ "$enrc" -ne 0 ] && [ "$acrc" -ne 0 ]
    else
        ! pgrep -u "$USER" -f 'moshi-hook serve' >/dev/null 2>&1
    fi
}
