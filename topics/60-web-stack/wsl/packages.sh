#!/usr/bin/env bash
# Custom: WSL base packages — mysql, redis, nginx, php-fpm per version.

_required_packages() {
    local pkgs=(mysql-server-8.0 redis-server nginx)
    local ver
    for ver in ${PHP_VERSIONS:-${PHP_DEFAULT:-}}; do
        [[ -z "$ver" ]] && continue
        pkgs+=("php${ver}-fpm")
    done
    printf '%s\n' "${pkgs[@]}"
}

check() {
    local p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        dpkg -s "$p" >/dev/null 2>&1 || return 1
    done < <(_required_packages)
    return 0
}

install() {
    sudo -v 2>/dev/null || true
    export DEBIAN_FRONTEND=noninteractive
    local APT=(-y -q
        -o Dpkg::Options::="--force-confdef"
        -o Dpkg::Options::="--force-confold")

    local missing=() p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done < <(_required_packages)

    if (( ${#missing[@]} > 0 )); then
        sudo apt-get update -q
        sudo apt-get install "${APT[@]}" --no-install-recommends "${missing[@]}"
    fi
}

verify() {
    check
}

rollback() {
    # Don't auto-uninstall — data-loss risk for mysql + user expectation.
    :
}
