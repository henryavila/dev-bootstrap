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

repair() { install; }

rollback() {
    :
}

uninstall() {
    # Reverse install-mssql-driver.sh (WSL/Debian only — Mac install is manual,
    # so there is nothing this verb removes on Darwin). install() does, in order:
    #   1. apt: msodbcsql18, mssql-tools18, unixodbc-dev (+ per-PHP php<ver>-dev)
    #   2. Microsoft APT source + keyring it created
    #   3. /etc/profile.d/mssql-tools.sh PATH snippet it wrote
    #   4. PECL sqlsrv + pdo_sqlsrv built + `phpenmod`-enabled per PHP version
    # We undo 1-4 scoped strictly to mesh-managed paths. Shared deps are LEFT:
    #   - unixodbc-dev is a generic ODBC build dep other drivers may need → keep.
    #   - php<ver>-dev is owned by the languages bundle (10-languages installs it
    #     for all PECL builds) → keep; we only added it defensively for a
    #     standalone run.
    # Success is gated on `! check` so the engine's marker drop is honest: we
    # only confirm removal when the driver packages are gone AND no configured
    # PHP version still loads the extensions.

    # Mac: install is manual (heavy-lifter exits 0 off Ubuntu/Debian), so there
    # is nothing we own to remove. Documented no-op for this platform.
    case "$(uname -s)" in
        Linux) : ;;
        *) return 0 ;;
    esac

    local ver php_bin

    # ── 4. PECL extensions: disable then uninstall per configured PHP version ──
    # phpdismod (reverse of install's phpenmod) is what actually makes `php -m`
    # stop reporting the ext — the exact signal check() probes. `pecl uninstall`
    # then clears the registry/.so; both are best-effort (the version may be gone
    # already, or the ext never built). The 4-env-var pinning install used isn't
    # needed to *disable*: phpdismod -v binds the version directly.
    for ver in ${PHP_VERSIONS:-${PHP_DEFAULT:-}}; do
        [[ -z "$ver" ]] && continue
        if command -v phpdismod >/dev/null 2>&1; then
            sudo phpdismod -v "$ver" pdo_sqlsrv >/dev/null 2>&1 || true
            sudo phpdismod -v "$ver" sqlsrv     >/dev/null 2>&1 || true
        fi
        # Remove what install() actually wrote. `pecl uninstall` is best-effort
        # AND usually a no-op: install built the extensions with an ISOLATED
        # PHP_PEAR_METADATA_DIR (mktemp'd then deleted), so the default PEAR
        # registry has no record — leaving the .so + the mods-available .ini stubs
        # orphaned. So also delete those directly, scoped to mesh-written paths.
        php_bin="$(command -v "php${ver}" 2>/dev/null)" || php_bin=""
        if [[ -n "$php_bin" ]] && command -v pecl >/dev/null 2>&1; then
            PHP_PEAR_PHP_BIN="$php_bin" sudo -E pecl uninstall "pdo_sqlsrv" >/dev/null 2>&1 || true
            PHP_PEAR_PHP_BIN="$php_bin" sudo -E pecl uninstall "sqlsrv"     >/dev/null 2>&1 || true
        fi
        # The mods-available .ini stubs install wrote (phpdismod only drops the
        # conf.d symlink, never these).
        sudo rm -f "/etc/php/${ver}/mods-available/sqlsrv.ini" \
                   "/etc/php/${ver}/mods-available/pdo_sqlsrv.ini" 2>/dev/null || true
        # The built .so in this version's extension_dir. `php -r ini_get` prints
        # the dir directly — no pipe, so no pipefail/broken-pipe race.
        if [[ -n "$php_bin" ]]; then
            local extdir
            extdir="$("$php_bin" -r 'echo ini_get("extension_dir");' 2>/dev/null)" || extdir=""
            if [[ -n "$extdir" && -d "$extdir" ]]; then
                sudo rm -f "$extdir/sqlsrv.so" "$extdir/pdo_sqlsrv.so" 2>/dev/null || true
            fi
        fi
    done

    # Restart any running FPMs so the now-disabled extension is dropped from the
    # live worker (mirror of install's restart pass). Best-effort.
    for ver in ${PHP_VERSIONS:-${PHP_DEFAULT:-}}; do
        [[ -z "$ver" ]] && continue
        if command -v systemctl >/dev/null 2>&1 \
            && systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null; then
            sudo systemctl restart "php${ver}-fpm" >/dev/null 2>&1 || true
        fi
    done

    # ── 1. apt packages: remove the driver + tools install() hardwired ──────────
    # purge (not just remove) so msodbcsql18's odbcinst.ini stanza + configs are
    # gone — a stale "ODBC Driver 18 for SQL Server" registration would otherwise
    # leave check()'s odbcinst probe passing. unixodbc-dev is a shared build dep:
    # NOT removed (another ODBC driver bundle may rely on it).
    if command -v apt-get >/dev/null 2>&1; then
        for pkg in mssql-tools18 msodbcsql18; do
            if dpkg -s "$pkg" >/dev/null 2>&1; then
                sudo ACCEPT_EULA=Y apt-get purge -y -qq "$pkg" >/dev/null 2>&1 || true
            fi
        done
    fi

    # ── 3. PATH snippet install() wrote for sqlcmd/bcp ─────────────────────────
    sudo rm -f /etc/profile.d/mssql-tools.sh 2>/dev/null || true

    # ── 2. Microsoft APT source + keyring install() created ────────────────────
    # Both files are written by THIS installer and (per repo grep) no other
    # bundle consumes them, so removing them only reverts what install() added.
    sudo rm -f /etc/apt/sources.list.d/mssql-release.list \
               /etc/apt/keyrings/microsoft.gpg 2>/dev/null || true
    # Refresh the apt cache so the dropped source stops being referenced. Tolerate
    # failure (offline, locked dpkg) — it doesn't affect removal correctness.
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq >/dev/null 2>&1 || true
    fi

    # Honest success gate: removed only when the driver package is gone AND no
    # configured PHP version still loads the extensions. check() can't be reused:
    # its `dpkg -s msodbcsql18 || return 1` SHORT-CIRCUITS before the per-PHP ext
    # probe, so it would report "removed" the instant the package is purged even
    # if phpdismod failed and the ext stayed enabled. Probe both arms here.
    dpkg -s msodbcsql18 >/dev/null 2>&1 && return 1   # driver package still installed
    for ver in ${PHP_VERSIONS:-${PHP_DEFAULT:-}}; do
        [[ -z "$ver" ]] && continue
        php_bin="$(command -v "php${ver}" 2>/dev/null)" || continue
        # capture-then-test (pipefail-safe; no `php -m | grep -q` broken-pipe
        # race). "sqlsrv" substring catches both sqlsrv and pdo_sqlsrv.
        local mods
        mods="$("$php_bin" -m 2>/dev/null)" || mods=""
        [[ "$mods" == *sqlsrv* ]] && return 1   # extension still enabled
    done
    return 0
}
