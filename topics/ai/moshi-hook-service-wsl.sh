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
