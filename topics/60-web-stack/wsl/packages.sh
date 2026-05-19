#!/usr/bin/env bash
# Custom: WSL base packages — mysql, redis, nginx, php-fpm per version.

_required_packages() {
    # Codex review 2026-05-19 (C-F005): when both PHP_VERSIONS and
    # PHP_DEFAULT are empty the previous body produced "(mysql redis nginx)"
    # only — no `phpX.Y-fpm` packages were ever added. check() then reported
    # success once those 3 packages were installed, and Laravel/PHP sites
    # silently couldn't run because no FPM was wired up. Now we resolve
    # versions from PHP_VERSIONS → PHP_DEFAULT → topic 10-languages's
    # data/php-versions.conf, and fail loudly if all 3 are empty.
    local pkgs=(mysql-server-8.0 redis-server nginx)
    local versions="${PHP_VERSIONS:-${PHP_DEFAULT:-}}"
    if [[ -z "$versions" ]]; then
        local conf
        conf="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../10-languages" 2>/dev/null && pwd)/data/php-versions.conf"
        if [[ -f "$conf" ]]; then
            versions="$(grep -vE '^\s*(#|$)' "$conf" | xargs)"
        fi
    fi
    if [[ -z "$versions" ]]; then
        echo "[60-web-stack/packages] PHP_VERSIONS and PHP_DEFAULT both empty and 10-languages/data/php-versions.conf unreadable — refusing to install web stack without any php-fpm. Set PHP_VERSIONS=8.3 8.4 (etc.) and re-run." >&2
        return 1
    fi
    local ver
    for ver in $versions; do
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
