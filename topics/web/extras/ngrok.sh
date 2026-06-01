#!/usr/bin/env bash
# Custom wrapper: ngrok (web/ngrok bundle).
# v2: bundle selection is the gate — no INCLUDE_* guard needed. The auth token
# is supplied via the bundle's NGROK_AUTHTOKEN option (params/secrets.env).

check() {
    command -v ngrok >/dev/null 2>&1
}

install() {
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
