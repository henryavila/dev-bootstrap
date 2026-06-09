#!/usr/bin/env bash
# Custom: WSL web packages — nginx + php-fpm per version.
#
# v2 split (web/nginx-php-fpm bundle): mysql-server-8.0 and redis-server moved
# to the databases topic (databases/mysql, databases/redis) as native apt
# items. This script now installs only nginx + the php-fpm packages; the
# databases/* bundles are pulled in via web/nginx-php-fpm's requires_bundles.

_required_packages() {
    # Codex review 2026-05-19 (C-F005): when both PHP_VERSIONS and
    # PHP_DEFAULT are empty the previous body produced "(nginx)" only — no
    # `phpX.Y-fpm` packages were ever added. check() then reported success
    # once nginx was installed, and Laravel/PHP sites silently couldn't run
    # because no FPM was wired up. Now we resolve versions from
    # PHP_VERSIONS → PHP_DEFAULT → topic languages's data/php-versions.conf,
    # and fail loudly if all 3 are empty.
    local pkgs=(nginx)
    local versions="${PHP_VERSIONS:-${PHP_DEFAULT:-}}"
    if [[ -z "$versions" ]]; then
        local conf
        # languages topic still resolves under topics/ (../../languages once
        # the languages topic is migrated; ../../10-languages until then).
        conf="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../languages" 2>/dev/null && pwd)/data/php-versions.conf"
        [[ -f "$conf" ]] || conf="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../10-languages" 2>/dev/null && pwd)/data/php-versions.conf"
        if [[ -f "$conf" ]]; then
            versions="$(grep -vE '^\s*(#|$)' "$conf" | xargs)"
        fi
    fi
    if [[ -z "$versions" ]]; then
        echo "[web/nginx-php-fpm] PHP_VERSIONS and PHP_DEFAULT both empty and languages/data/php-versions.conf unreadable — refusing to install the web stack without any php-fpm. Set PHP_VERSIONS=8.3 8.4 (etc.) and re-run." >&2
        return 1
    fi
    local ver
    for ver in $versions; do
        [[ -z "$ver" ]] && continue
        pkgs+=("php${ver}-fpm")
    done
    printf '%s\n' "${pkgs[@]}"
}

# Resolve the configured PHP versions only (no nginx, no php prefix) — used by
# verify()'s functional probe. Mirrors _required_packages's resolution order
# (PHP_VERSIONS → PHP_DEFAULT → languages/data/php-versions.conf) so check()
# and verify() agree on which versions are in scope. Prints one bare version
# per line; prints nothing (and the caller treats it as a hard fail) when none
# resolve — install() refuses to run without any version, so verify() must too.
_php_fpm_versions() {
    local versions="${PHP_VERSIONS:-${PHP_DEFAULT:-}}"
    if [[ -z "$versions" ]]; then
        local conf
        conf="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../languages" 2>/dev/null && pwd)/data/php-versions.conf"
        [[ -f "$conf" ]] || conf="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../10-languages" 2>/dev/null && pwd)/data/php-versions.conf"
        if [[ -f "$conf" ]]; then
            versions="$(grep -vE '^\s*(#|$)' "$conf" | xargs)"
        fi
    fi
    local ver
    for ver in $versions; do
        [[ -z "$ver" ]] && continue
        printf '%s\n' "$ver"
    done
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
    # Post-install + --repair sweep gate. Stronger than check(): check() asserts
    # only `dpkg -s` presence, which a half-configured/broken package satisfies.
    # Here we also assert the artifacts install() implies are FUNCTIONAL —
    # within this item's scope only (nginx + php-fpm per version). The PHP
    # extensions are owned by languages/php-stack-wsl, so we deliberately do NOT
    # probe them here; that would false-fail this item for another item's gap.
    check || return 1

    # nginx binary present. Debian/Ubuntu lands it in /usr/sbin; accept the PATH
    # name OR the canonical sbin path (symmetric with the php-fpm probe below) so
    # a verify-context PATH lacking /usr/sbin can't false-fail. Fast + sudo-free.
    command -v nginx >/dev/null 2>&1 || [[ -x /usr/sbin/nginx ]] || return 1

    # Each configured php-fpm binary must actually execute — proves the package
    # is fully configured and the binary loads, not just unpacked. Debian/Ubuntu
    # (ondrej/php PPA) ships it as /usr/sbin/php-fpm<ver>. We accept either the
    # PATH name or the canonical sbin path; --version is a no-side-effect probe.
    local ver fpm
    while IFS= read -r ver; do
        [[ -z "$ver" ]] && continue
        fpm=""
        if command -v "php-fpm${ver}" >/dev/null 2>&1; then
            fpm="php-fpm${ver}"
        elif [[ -x "/usr/sbin/php-fpm${ver}" ]]; then
            fpm="/usr/sbin/php-fpm${ver}"
        else
            return 1
        fi
        "$fpm" --version >/dev/null 2>&1 || return 1
    done < <(_php_fpm_versions)
    return 0
}

rollback() {
    # Don't auto-uninstall — data-loss risk for mysql + user expectation.
    :
}
