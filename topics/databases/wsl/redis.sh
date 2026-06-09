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

uninstall() {
    # Reverse install(): purge the redis-server package this item added.
    # install() only `apt-get install redis-server` from the distro repo —
    # it adds NO apt source or keyring (unlike wsl/mysql.sh), so there is
    # nothing else to clean up. Scoped to redis-server only; we deliberately
    # do NOT run `apt-get autoremove` so a shared dependency another bundle
    # relies on is never pulled out from under it.
    #
    # rollback() stays a no-op (it fires on a failed install, where nuking a
    # pre-existing redis would be data loss). uninstall() is explicit user
    # intent (`mesh uninstall` / bundle deselection), so a real purge is the
    # honest reversal — and we gate the engine's marker drop on the package
    # actually being gone, mirroring ngrok.
    case "$(uname -s)" in
        Linux*) ;;
        *) return 0 ;;   # WSL-only item; off-platform = nothing was installed
    esac
    command -v apt-get >/dev/null 2>&1 || return 0

    if dpkg -s "$PKG" >/dev/null 2>&1; then
        sudo -v 2>/dev/null || true
        export DEBIAN_FRONTEND=noninteractive
        local rc=0
        sudo apt-get purge -y -qq "$PKG" 2>/dev/null || rc=$?
        [[ "$rc" -eq 0 ]] || printf 'redis: apt-get purge %s returned %s\n' "$PKG" "$rc" >&2
    fi

    # Success = the package is actually gone, so the engine's marker drop is
    # honest. Capture dpkg-query output first, then match — under pipefail a
    # `dpkg-query | grep -q` has a broken-pipe race (bash 3.2 / macOS floor).
    local status
    status="$(dpkg-query -W -f='${Status}\n' -- "$PKG" 2>/dev/null)"
    [[ "$status" != *"install ok installed"* ]]
}
