#!/usr/bin/env bash
# Custom wrapper: MS SQL Server ODBC driver + PHP sqlsrv extensions
# (gated by INCLUDE_MSSQL=1; WSL only — Mac install is manual).

check() {
    [[ "${INCLUDE_MSSQL:-0}" == "1" ]] || return 0
    dpkg -s msodbcsql18 >/dev/null 2>&1 \
        && dpkg -s unixodbc-dev >/dev/null 2>&1
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
