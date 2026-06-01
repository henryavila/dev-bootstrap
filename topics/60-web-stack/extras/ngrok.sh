#!/usr/bin/env bash
# Custom wrapper: ngrok (gated by INCLUDE_NGROK=1).

check() {
    # Probe system state unconditionally — the menu scanner needs a real
    # answer regardless of whether INCLUDE_NGROK is exported. The gate
    # stays in install() for back-compat with the legacy non-menu flow;
    # the menu's --items= filter is the authoritative opt-in path now.
    command -v ngrok >/dev/null 2>&1
}

install() {
    [[ "${INCLUDE_NGROK:-0}" == "1" ]] || return 0
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bash "$here/../scripts/install-ngrok.sh"
}

verify() {
    check
}

rollback() {
    :
}
