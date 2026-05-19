#!/usr/bin/env bash
# Custom wrapper: PostgreSQL (gated by INCLUDE_POSTGRES=1).

check() {
    [[ "${INCLUDE_POSTGRES:-0}" == "1" ]] || return 0
    # Codex review 2026-05-19 (C-F001): `command -v postgres` fails after a
    # supported install because brew formula `postgresql@17` puts the
    # binary in $BREW_PREFIX/opt/postgresql@17/bin (not on PATH by default)
    # and apt installs `postgresql-17` under /usr/lib/postgresql/17/bin.
    # The installer would re-run on every bootstrap. Now we check the
    # version-specific package the installer would install, then probe
    # pg_isready for liveness.
    local ver="${POSTGRES_VERSION:-17}"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        "${BREW_BIN:-brew}" list --formula "postgresql@${ver}" >/dev/null 2>&1 || return 1
    else
        dpkg -s "postgresql-${ver}" >/dev/null 2>&1 || return 1
    fi
    pg_isready -q 2>/dev/null
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
