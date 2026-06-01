#!/usr/bin/env bash
# Custom wrapper: MS SQL Server ODBC driver + PHP sqlsrv extensions
# (databases/mssql-driver bundle; WSL only — Mac install is manual).
# v2: bundle selection is the gate — no INCLUDE_* guard.
# NOTE: this single item installs the ODBC driver AND (when PHP is present)
# the PECL sqlsrv/pdo_sqlsrv extensions. The install-mssql-driver.sh heavy-
# lifter already no-ops the PECL pass when no PHP version is found, so the
# spec's separate `sqlsrv-php-ext` (when: php_installed) item is intentionally
# deferred until the engine's when: resolver (T-201) exists to validate the
# split end-to-end — splitting the battle-tested PECL script blind is risky.

check() {
    #
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
    local ver php_bin
    for ver in ${PHP_VERSIONS:-${PHP_DEFAULT:-}}; do
        [[ -z "$ver" ]] && continue
        dpkg -s "php${ver}-dev" >/dev/null 2>&1 || continue
        php_bin="$(command -v "php${ver}" 2>/dev/null)" || return 1
        "$php_bin" -m 2>/dev/null | grep -q '^sqlsrv$'     || return 1
        "$php_bin" -m 2>/dev/null | grep -q '^pdo_sqlsrv$' || return 1
    done
    return 0
}

install() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bash "$here/scripts/install-mssql-driver.sh"
}

verify() {
    check
}

rollback() {
    :
}
