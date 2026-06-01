#!/usr/bin/env bash
# Custom: WSL Redis server (databases/redis — wsl item).
#
# Split out of the old 60-web-stack/wsl/packages.sh. Installs only
# redis-server with the same noninteractive apt discipline used for the
# rest of the WSL stack.

PKG="redis-server"

check() {
    dpkg-query -W -f='${Status}\n' -- "$PKG" 2>/dev/null | grep -q '^install ok installed$'
}

install() {
    check && return 0
    sudo -v 2>/dev/null || true
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -q
    sudo apt-get install -y -q \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        --no-install-recommends "$PKG"
}

verify() { check; }

rollback() {
    # Don't auto-uninstall — data-loss risk + user expectation.
    :
}
