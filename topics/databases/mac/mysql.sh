#!/usr/bin/env bash
# Custom: MySQL 8 on macOS (brew formula with Oracle DMG fallback).

ORACLE_MYSQL_BIN="/usr/local/mysql/bin/mysql"

check() {
    [[ -x "$ORACLE_MYSQL_BIN" ]] && return 0
    "${BREW_BIN:-brew}" list --formula mysql@8.0 >/dev/null 2>&1
}

install() {
    if [[ -x "$ORACLE_MYSQL_BIN" ]]; then
        local paths_file="/etc/paths.d/61-oracle-mysql"
        if ! sudo grep -q "^/usr/local/mysql/bin$" "$paths_file" 2>/dev/null; then
            echo "/usr/local/mysql/bin" | sudo tee "$paths_file" >/dev/null
        fi
        return 0
    fi
    "${BREW_BIN:-brew}" install mysql@8.0 || return 1
    "${BREW_BIN:-brew}" link --force --overwrite mysql@8.0 >/dev/null 2>&1 || true
    "${BREW_BIN:-brew}" services start mysql@8.0 >/dev/null 2>&1 || true
}

verify() {
    check
}

rollback() {
    # Don't auto-uninstall MySQL — data loss risk if user has dbs.
    :
}
