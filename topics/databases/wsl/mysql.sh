#!/usr/bin/env bash
# Custom: MySQL 9 (LTS) on WSL/Ubuntu via Oracle's APT repository.
#
# Ubuntu's own repos cap at mysql-server-8.0, so for MySQL 9 we add Oracle's
# APT repo (repo.mysql.com/apt/ubuntu) directly — a `signed-by` keyring + a
# source line pinned to the `mysql-9.7-lts` component (the stable 9.x LTS; the
# `mysql-innovation` track churns and goes EOL fast). Trust anchor is the same
# MySQL Release Engineering key as the mac path (fpr BCA4…785C), which also
# signs this repo's Release file — verified, and pinned here too.
#
# Keeps the noninteractive apt discipline (DEBIAN_FRONTEND + --force-conf* +
# explicit apt-get update) so neither the repo refresh nor the unattended
# server install can stall on a debconf prompt or a stale index.
#
# Existing mysql-server-8.0 (the distro package this file used to install) is
# left UNTOUCHED: 8.0→9 is not a direct in-place upgrade (MySQL requires going
# through 8.4 LTS first) and the packages conflict, so auto-swapping risks data
# loss. Such machines get a clear advisory; migration is a deliberate step.

PKG="mysql-community-server"
DISTRO_PKG="mysql-server-8.0"
MYSQL_COMPONENT="mysql-9.7-lts"
MYSQL_APT_URL="https://repo.mysql.com/apt/ubuntu"
MYSQL_GPG_FPR="BCA43417C3B485DD128EC6D4B7B3B788A8D3785C"
MYSQL_GPG_KEY_URL="https://repo.mysql.com/RPM-GPG-KEY-mysql-2025"
MYSQL_KEYRING="/etc/apt/keyrings/mysql.gpg"
MYSQL_SOURCES="/etc/apt/sources.list.d/mysql.list"

_codename() {
    local c=""
    [[ -r /etc/os-release ]] && c="$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}")"
    [[ -n "$c" ]] || c="$(lsb_release -cs 2>/dev/null || true)"
    printf '%s' "$c"
}

_has_systemd() { [[ -d /run/systemd/system ]]; }

_pkg_installed() {
    dpkg-query -W -f='${Status}\n' -- "$PKG" 2>/dev/null | grep -q '^install ok installed$'
}

_distro_mysql8_present() {
    dpkg-query -W -f='${Status}\n' -- "$DISTRO_PKG" 2>/dev/null | grep -q '^install ok installed$'
}

_server_running() {
    _has_systemd && systemctl is-active --quiet mysql 2>/dev/null && return 0
    pgrep -u mysql -x mysqld >/dev/null 2>&1
}

# T-006: apply this daemon's boot-state from the per-host services.default via the
# shared services lib (svc_enable/svc_disable), instead of forcing it on at boot
# with `enable --now`. Isolated subshell (the lib sets `set -uo pipefail`) +
# best-effort; never fatal to the install.
_apply_boot_state() {
    local recon
    recon="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd)/scripts/lib/services/reconcile.sh"
    [[ -f "$recon" ]] || return 0
    ( . "$recon" && services_reconcile_one "$1" ) 2>/dev/null || true
}

_start_server() {
    if _has_systemd; then
        sudo systemctl start mysql >/dev/null 2>&1 || true
        _apply_boot_state mysql            # boot-state via services.default, not enable --now
    else
        sudo service mysql start >/dev/null 2>&1 || true
    fi
}

# Add the GPG-verified Oracle APT repo (idempotent). Returns nonzero on any
# trust/availability failure so install() aborts before apt sees the source.
_add_mysql_repo() {
    local codename arch tmp
    codename="$(_codename)"
    arch="$(dpkg --print-architecture)"
    [[ -n "$codename" ]] || { echo "mysql: cannot detect Ubuntu codename" >&2; return 1; }
    case "$arch" in
        amd64|i386) : ;;
        *) echo "mysql: Oracle APT repo ships only amd64/i386 — no MySQL 9 for '$arch'" >&2; return 1 ;;
    esac
    if ! curl -fsI "${MYSQL_APT_URL}/dists/${codename}/Release" >/dev/null 2>&1; then
        echo "mysql: Oracle APT repo has no dist for '${codename}'" >&2; return 1
    fi

    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    curl -fsSL "$MYSQL_GPG_KEY_URL" -o "$tmp/mysql.key" \
        || { echo "mysql: GPG key download failed" >&2; return 1; }
    GNUPGHOME="$tmp" gpg --batch --import "$tmp/mysql.key" 2>/dev/null \
        || { echo "mysql: GPG key import failed" >&2; return 1; }
    GNUPGHOME="$tmp" gpg --batch --list-keys --with-colons 2>/dev/null | grep -q "$MYSQL_GPG_FPR" \
        || { echo "mysql: key fingerprint != pinned ${MYSQL_GPG_FPR} — refusing" >&2; return 1; }

    sudo mkdir -p /etc/apt/keyrings
    gpg --dearmor < "$tmp/mysql.key" | sudo tee "$MYSQL_KEYRING" >/dev/null
    sudo chmod 0644 "$MYSQL_KEYRING"
    printf 'deb [arch=%s signed-by=%s] %s %s %s\n' \
        "$arch" "$MYSQL_KEYRING" "$MYSQL_APT_URL" "$codename" "$MYSQL_COMPONENT" \
        | sudo tee "$MYSQL_SOURCES" >/dev/null
}

check() {
    # A pre-existing distro 8.0 counts as satisfied — migrating it to 9 is a
    # deliberate, data-sensitive step we never trigger from a generic apply.
    _distro_mysql8_present && return 0
    _pkg_installed || return 1
    _server_running
}

install() {
    if _distro_mysql8_present; then
        echo "mysql(wsl): ${DISTRO_PKG} present — MySQL 9 is NOT a direct upgrade" >&2
        echo "  (8.0 → 8.4 → 9.x, or dump+restore) and the packages conflict." >&2
        echo "  Leaving 8.0 in place; migrate deliberately, then re-run." >&2
        return 0
    fi

    # Already on the community 9.x package → just ensure the run layer.
    if _pkg_installed; then
        _server_running || _start_server
        return 0
    fi

    sudo -v 2>/dev/null || true
    export DEBIAN_FRONTEND=noninteractive

    sudo apt-get update -q
    sudo apt-get install -y -q --no-install-recommends ca-certificates gnupg curl || return 1

    _add_mysql_repo || return 1
    sudo apt-get update -q

    # Unattended: empty root password (dev parity with the mac — localhost
    # only) + strong auth. Credentials/auth validated for real on ultron/crc.
    echo "${PKG} ${PKG}/root-pass password "    | sudo debconf-set-selections
    echo "${PKG} ${PKG}/re-root-pass password " | sudo debconf-set-selections
    echo "${PKG} ${PKG}/default-auth-override select Use Strong Password Encryption (RECOMMENDED)" \
        | sudo debconf-set-selections

    sudo apt-get install -y -q \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        --no-install-recommends "$PKG" || return 1

    _start_server
}

verify() { check; }

rollback() {
    # Stop only — never purge the package or delete /var/lib/mysql (data loss).
    if _has_systemd; then
        sudo systemctl stop mysql 2>/dev/null || true
    else
        sudo service mysql stop 2>/dev/null || true
    fi
}

uninstall() {
    # Reverse install(): stop the server, REMOVE (not purge) the community 9.x
    # package, and drop ONLY the Oracle APT source + keyring this script added.
    #
    # Data-safe by design: `apt-get remove` (never `purge`) leaves /var/lib/mysql
    # and /etc/mysql untouched — this is a deliberate `mesh uninstall`, not the
    # crash-time rollback(), but a database's data dir is never ours to delete.
    #
    # install() explicitly leaves a pre-existing distro mysql-server-8.0 ALONE
    # (8.0→9 is not a direct upgrade and the packages conflict). uninstall()
    # honours the same boundary: it only ever removes the community package and
    # the repo files WE added — never the distro 8.0 package, its data, or any
    # mysql binary 8.0 might still provide.
    [[ "$(uname -s)" == Linux* ]] || return 0

    # Nothing of ours installed → honest no-op success (a lone distro 8.0, or a
    # never-installed machine, leaves no community package and no repo files).
    if ! _pkg_installed && [[ ! -e "$MYSQL_SOURCES" && ! -e "$MYSQL_KEYRING" ]]; then
        return 0
    fi

    sudo -v 2>/dev/null || true

    # Stop the server before package removal (best-effort; either init path).
    if _server_running; then
        if _has_systemd; then
            sudo systemctl disable --now mysql >/dev/null 2>&1 || true
        else
            sudo service mysql stop >/dev/null 2>&1 || true
        fi
    fi

    # Remove (not purge) the community server package if present.
    if _pkg_installed; then
        export DEBIAN_FRONTEND=noninteractive
        local rc=0
        sudo apt-get remove -y -q "$PKG" || rc=$?
        [[ "$rc" -eq 0 ]] || echo "mysql(wsl): apt-get remove $PKG returned $rc" >&2
    fi

    # Drop only the mesh-added APT source + keyring (scoped, mesh-managed paths).
    sudo rm -f "$MYSQL_SOURCES" "$MYSQL_KEYRING" 2>/dev/null || true

    # Refresh the index so the now-removed source can't leave a dangling entry.
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -q >/dev/null 2>&1 || true
    fi

    # Honest marker drop: success = OUR package is gone AND both repo files are
    # gone. Gating on _pkg_installed (not `command -v mysql`) is deliberate — a
    # surviving distro 8.0 would still provide a `mysql` binary that isn't ours.
    ! _pkg_installed && [[ ! -e "$MYSQL_SOURCES" && ! -e "$MYSQL_KEYRING" ]]
}
