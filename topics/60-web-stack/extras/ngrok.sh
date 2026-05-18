#!/usr/bin/env bash
# Custom wrapper: ngrok (gated by INCLUDE_NGROK=1).

check() {
    [[ "${INCLUDE_NGROK:-0}" == "1" ]] || return 0
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
