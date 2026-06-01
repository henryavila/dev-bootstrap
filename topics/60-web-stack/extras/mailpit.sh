#!/usr/bin/env bash
# Custom wrapper: mailpit (gated by INCLUDE_MAILPIT=1).
# Delegates to scripts/install-mailpit.sh which keeps its existing logic.

check() {
    # Probe system state unconditionally — the menu scanner needs a real
    # answer regardless of whether INCLUDE_MAILPIT is exported. The gate
    # stays in install() for back-compat with the legacy non-menu flow;
    # the menu's --items= filter is the authoritative opt-in path now.
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
