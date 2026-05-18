#!/usr/bin/env bash
# Custom wrapper: PostgreSQL (gated by INCLUDE_POSTGRES=1).

check() {
    [[ "${INCLUDE_POSTGRES:-0}" == "1" ]] || return 0
    command -v postgres >/dev/null 2>&1 && pg_isready -q 2>/dev/null
}

install() {
    [[ "${INCLUDE_POSTGRES:-0}" == "1" ]] || return 0
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bash "$here/../scripts/install-postgres.sh"
}

verify() {
    check
}

rollback() {
    :
}
