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
    # Now: assert the 3 dpkg packages the installer hardwires, the ODBC
    # driver's unixODBC registration, plus a PECL extension probe for every
    # configured PHP version (see the 2026-06-03 note below for why the old
    # skip-on-missing-`php<ver>-dev` shortcut was dropped).
    dpkg -s msodbcsql18    >/dev/null 2>&1 || return 1
    dpkg -s mssql-tools18  >/dev/null 2>&1 || return 1
    dpkg -s unixodbc-dev   >/dev/null 2>&1 || return 1
    #
    # 2026-06-03 (§D presence-gap hardening): the dpkg checks above prove the
    # .debs are unpacked, but not that the ODBC driver is actually *registered*
    # in unixODBC. msodbcsql18's postinst writes the "ODBC Driver 18 for SQL
    # Server" stanza into /etc/odbcinst.ini; a corrupt/hand-edited odbcinst.ini
    # leaves the package "installed" yet the driver unusable. odbcinst ships
    # with unixodbc (a dep of unixodbc-dev) so it is present on any healthy
    # install — but fall back gracefully if the tool is somehow missing so we
    # don't false-fail. No sudo: odbcinst -q -d reads world-readable config.
    if command -v odbcinst >/dev/null 2>&1; then
        odbcinst -q -d 2>/dev/null | grep -q 'ODBC Driver 18 for SQL Server' || return 1
    fi
    # Per-PHP functional probe. install() installs php${ver}-dev AND the PECL
    # sqlsrv/pdo_sqlsrv extensions for EVERY configured version, so a healthy
    # install has the ext loaded everywhere. We therefore assert it for every
    # configured version (no skip-on-missing-dev): a version that lost its
    # extension after a PHP upgrade — the exact partial-install this item must
    # catch — must report not-installed so the next pass reconciles it.
    local ver php_bin
    for ver in ${PHP_VERSIONS:-${PHP_DEFAULT:-}}; do
        [[ -z "$ver" ]] && continue
        php_bin="$(command -v "php${ver}" 2>/dev/null)" || return 1
        # Case-insensitive: `php -m` emits `PDO_SQLSRV` (uppercase) and `sqlsrv`
        # (lowercase). The repo's own pecl-install.sh / web/verify.sh use -qi for
        # exactly this — a case-sensitive grep here false-fails a healthy install.
        # Capture then grep a here-string — NOT `php -m | grep -q`: under the
        # engine's pipefail, grep -q closing the pipe early makes php exit non-zero
        # on the EPIPE → a false "ext missing". `<<<` reads a temp file (no producer
        # to SIGPIPE). See feedback_engine_pipefail_grep_q_broken_pipe (lint L21).
        local _mods; _mods="$("$php_bin" -m 2>/dev/null)"
        grep -qi '^sqlsrv$'     <<<"$_mods" || return 1
        grep -qi '^pdo_sqlsrv$' <<<"$_mods" || return 1
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
