#!/usr/bin/env bash
# Custom wrapper: MS SQL Server ODBC driver + PHP sqlsrv extensions
# (gated by INCLUDE_MSSQL=1; WSL only — Mac install is manual).

check() {
    [[ "${INCLUDE_MSSQL:-0}" == "1" ]] || return 0
    # Codex review 2026-05-19 (C-F002): the previous check accepted just
    # msodbcsql18 + unixodbc-dev as "installed", but install-mssql-driver.sh
    # also installs mssql-tools18 + per-PHP `php<ver>-dev` + PECL sqlsrv
    # and pdo_sqlsrv. A partial install (e.g. one PHP version missing the
    # PECL extensions after upgrade) would silently report success.
    # Now: assert the 3 dpkg packages the installer hardwires, plus a
    # PECL extension probe per PHP version that's actually present
    # on this host (skipping versions that have no `php<ver>-dev` —
    # those are reconciled by the next install pass).
    dpkg -s msodbcsql18    >/dev/null 2>&1 || return 1
    dpkg -s mssql-tools18  >/dev/null 2>&1 || return 1
    dpkg -s unixodbc-dev   >/dev/null 2>&1 || return 1
    local ver pecl_bin
    for ver in ${PHP_VERSIONS:-${PHP_DEFAULT:-}}; do
        [[ -z "$ver" ]] && continue
        # Only enforce PECL state for versions whose dev pkg the installer
        # would have used (others aren't candidates for this pass).
        dpkg -s "php${ver}-dev" >/dev/null 2>&1 || continue
        pecl_bin="$(command -v "pecl${ver}" 2>/dev/null || command -v pecl 2>/dev/null)"
        [[ -n "$pecl_bin" ]] || return 1
        "$pecl_bin" list -c "php${ver}" 2>/dev/null | grep -q '^sqlsrv\b'     || return 1
        "$pecl_bin" list -c "php${ver}" 2>/dev/null | grep -q '^pdo_sqlsrv\b' || return 1
    done
    return 0
}

install() {
    [[ "${INCLUDE_MSSQL:-0}" == "1" ]] || return 0
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bash "$here/../scripts/install-mssql-driver.sh"
}

verify() {
    check
}

rollback() {
    :
}
