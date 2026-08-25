#!/usr/bin/env bash
# Custom: WSL web packages — nginx + php-fpm per version.
#
# v2 split (web/nginx-php-fpm bundle): mysql-server-8.0 and redis-server moved
# to the databases topic (databases/mysql, databases/redis) as native apt
# items. This script now installs nginx, iproute2 (the sudo-free `ss` listener
# probe), and the php-fpm packages; the databases/* bundles are pulled in via
# web/nginx-php-fpm's requires_bundles.

_WEB_WSL_PACKAGES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./php-runtime.sh
. "$_WEB_WSL_PACKAGES_DIR/php-runtime.sh"

_required_packages() {
    # Codex review 2026-05-19 (C-F005): when both PHP_VERSIONS and
    # PHP_DEFAULT are empty the previous body produced "(nginx)" only — no
    # `phpX.Y-fpm` packages were ever added. check() then reported success
    # once nginx was installed, and Laravel/PHP sites silently couldn't run
    # because no FPM was wired up. Resolve the declaration when present, or
    # the runtime that languages/php already converged across a bundle boundary.
    local pkgs=(nginx iproute2)
    local versions
    versions="$(_mesh_web_php_runtime_versions)" || return 1
    local ver
    for ver in $versions; do
        [[ -z "$ver" ]] && continue
        pkgs+=("php${ver}-fpm")
    done
    printf '%s\n' "${pkgs[@]}"
}

# Resolve the configured PHP versions only (no nginx, no php prefix) — used by
# verify()'s functional probe. Uses the same shared boundary as install() so
# check() and verify() agree on which versions are in scope.
_php_fpm_versions() {
    _mesh_web_php_runtime_versions
}

check() {
    local required p
    required="$(_required_packages)" || return 1
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        dpkg -s "$p" >/dev/null 2>&1 || return 1
    done <<< "$required"
    return 0
}

install() {
    # Resolve the languages/php boundary before sudo or apt/dpkg mutation. A
    # process substitution would discard the producer's non-zero status and
    # make an empty package set look converged.
    local required
    required="$(_required_packages)" || return 1
    sudo -n -v >/dev/null 2>&1 || true
    export DEBIAN_FRONTEND=noninteractive
    local APT=(-y -q
        -o Dpkg::Options::="--force-confdef"
        -o Dpkg::Options::="--force-confold")

    # Finish any interrupted/half-configured packages first — a dpkg left in
    # "install ok half-configured" satisfies `dpkg -s` (rc 0) yet fails
    # verify()'s functional probe (`php-fpm<ver> --version` won't run), so a
    # repair that only reinstalls truly-absent packages would loop the engine
    # to "still broken after repair". `--configure -a` is cheap + idempotent.
    sudo dpkg --configure -a >/dev/null 2>&1 || true

    # A package needs (re)install when it is absent OR present but NOT fully
    # "install ok installed" — mirrors the functional gate verify() applies
    # (cf. foundation/wsl/core.sh _pkg_healthy), so a half-configured package
    # the strong probe rejects is actually reconciled by repair().
    local missing=() p _status
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        _status="$(dpkg -s "$p" 2>/dev/null | sed -n 's/^Status: //p')"
        [[ "$_status" == "install ok installed" ]] || missing+=("$p")
    done <<< "$required"

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
    local versions ver fpm
    versions="$(_php_fpm_versions)" || return 1
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
    done <<< "$versions"
    return 0
}

repair() { install; }

rollback() {
    # Don't auto-uninstall — data-loss risk for mysql + user expectation.
    :
}
