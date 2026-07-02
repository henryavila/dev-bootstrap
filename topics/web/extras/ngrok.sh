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

repair() { install; }

rollback() {
    :
}

uninstall() {
    # Reverse install-ngrok.sh: drop the agent (brew cask on mac, apt on Linux)
    # and the apt source/keyring it added. The companion `share-project` CLI is a
    # deploy-rendered template owned by the web bundle, left in place here.
    case "$(uname -s)" in
        Darwin)
            command -v brew >/dev/null 2>&1 && "${BREW_BIN:-brew}" uninstall --cask ngrok 2>/dev/null || true
            ;;
        Linux)
            command -v apt-get >/dev/null 2>&1 && sudo apt-get remove -y -qq ngrok 2>/dev/null || true
            sudo rm -f /etc/apt/sources.list.d/ngrok.list /etc/apt/keyrings/ngrok.asc 2>/dev/null || true
            ;;
    esac
    # Success = the binary is actually gone, so the engine's marker drop is honest.
    ! command -v ngrok >/dev/null 2>&1
}
