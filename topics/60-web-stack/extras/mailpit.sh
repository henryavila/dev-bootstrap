#!/usr/bin/env bash
# Custom wrapper: mailpit (gated by INCLUDE_MAILPIT=1).
# Delegates to scripts/install-mailpit.sh which keeps its existing logic.

check() {
    [[ "${INCLUDE_MAILPIT:-0}" == "1" ]] || return 0
    command -v mailpit >/dev/null 2>&1
}

install() {
    [[ "${INCLUDE_MAILPIT:-0}" == "1" ]] || return 0
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bash "$here/../scripts/install-mailpit.sh"
}

verify() {
    check
}

rollback() {
    :
}
