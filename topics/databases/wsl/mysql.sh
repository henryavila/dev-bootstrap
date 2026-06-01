#!/usr/bin/env bash
# Custom: WSL MySQL 8 server (databases/mysql — wsl item).
#
# Split out of the old 60-web-stack/wsl/packages.sh. Installs only
# mysql-server-8.0, preserving that script's noninteractive apt discipline
# (DEBIAN_FRONTEND + --force-conf* + an explicit apt-get update) so the
# server install can't stall on a debconf prompt or a stale package index.

PKG="mysql-server-8.0"

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
    # Don't auto-uninstall — data-loss risk for mysql + user expectation.
    :
}
