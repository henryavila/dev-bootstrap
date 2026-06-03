#!/usr/bin/env bash
# Custom wrapper: PostgreSQL (databases/postgresql bundle).
# v2: bundle selection is the gate — no INCLUDE_* guard. Major version comes
# from the bundle's POSTGRES_VERSION option (params.env), default 17.

check() {
    #
    # Codex review 2026-05-19 (C-F001): `command -v postgres` fails after a
    # supported install because brew formula `postgresql@17` puts the
    # binary in $BREW_PREFIX/opt/postgresql@17/bin (not on PATH by default)
    # and apt installs `postgresql-17` under /usr/lib/postgresql/17/bin.
    # The installer would re-run on every bootstrap. Now we check the
    # version-specific package the installer would install, then probe
    # pg_isready for liveness.
    local ver="${POSTGRES_VERSION:-17}"
    local pgready="pg_isready"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        "${BREW_BIN:-brew}" list --formula "postgresql@${ver}" >/dev/null 2>&1 || return 1
        # postgresql@N is keg-only on macOS: brew does NOT symlink pg_isready
        # into $BREW_PREFIX/bin, so a bare `pg_isready` is not found and the
        # engine post-verify aborts the whole run (rc 67) even after a correct
        # install. Resolve the keg-only binary via its version-specific opt path
        # (same location install-postgres.sh uses), falling back to PATH.
        command -v pg_isready >/dev/null 2>&1 \
            || pgready="${BREW_PREFIX:-/opt/homebrew}/opt/postgresql@${ver}/bin/pg_isready"
    else
        dpkg -s "postgresql-${ver}" >/dev/null 2>&1 || return 1
    fi
    "$pgready" -q 2>/dev/null
}

install() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bash "$here/scripts/install-postgres.sh"
}

verify() {
    check
}

rollback() {
    :
}
