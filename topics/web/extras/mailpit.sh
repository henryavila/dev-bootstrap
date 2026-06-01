#!/usr/bin/env bash
# Custom wrapper: mailpit (web/mailpit bundle).
# Delegates to scripts/install-mailpit.sh which keeps its existing logic.
# v2: bundle selection is the gate — the engine runs install() only when the
# user selected web/mailpit, so no INCLUDE_* guard is needed.

check() {
    command -v mailpit >/dev/null 2>&1
}

install() {
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
