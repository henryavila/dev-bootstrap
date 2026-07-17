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

repair() { install; }

rollback() {
    :
}

uninstall() {
    # Reverse install-postgres.sh: stop the service, then remove the
    # version-specific PostgreSQL package the installer added. The major is
    # resolved exactly as check()/install() do (POSTGRES_VERSION, default 17),
    # and EVERY removal is scoped to that one major so a parallel cluster of a
    # different major (which the installer hard-stops on, never creates) is left
    # untouched.
    #
    # DELIBERATELY PRESERVED (user data — never guess-deleted):
    #   - the cluster data directory ($BREW_PREFIX/var/postgresql@N on mac;
    #     /var/lib/postgresql/N on Debian, owned by the postgres package's
    #     postrm policy, not us)
    #   - the superuser role '$USER' and database '$USER' the installer created
    #   Removing those would destroy databases. `mesh uninstall` drops the
    #   tooling; it does not drop the user's data. apt `purge` is intentionally
    #   NOT used for that reason — `remove` leaves the cluster + conf intact.
    local ver="${POSTGRES_VERSION:-17}"
    # Only a numeric major lands in package/path args (symmetry with
    # install-postgres.sh). All uses are quoted so a bad value can't glob or
    # broad-delete, but reject it early rather than no-op + keep a stale marker.
    [[ "$ver" =~ ^[0-9]+$ ]] || { echo "postgresql: invalid POSTGRES_VERSION '$ver'" >&2; return 1; }

    case "$(uname -s)" in
        Darwin)
            command -v brew >/dev/null 2>&1 || return 0
            local brew_bin="${BREW_BIN:-brew}"

            # Stop the service first so the package can be removed cleanly.
            # Two start paths in install(): brew-services (canonical prefix) or
            # a launch-wrapper LaunchAgent (custom BREW_PREFIX). Tear down both;
            # each is idempotent and a no-op when its path wasn't used.
            "$brew_bin" services stop "postgresql@${ver}" 2>/dev/null || true

            local here wrc=0
            here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            if [[ -r "$here/../../scripts/lib/launch-wrapper.sh" ]]; then
                # shellcheck disable=SC1091
                . "$here/../../scripts/lib/launch-wrapper.sh" 2>/dev/null || wrc=$?
                if [[ "$wrc" -eq 0 ]] && declare -f launch_wrapper_teardown >/dev/null 2>&1; then
                    launch_wrapper_teardown "com.${USER}.postgresql@${ver}" 2>/dev/null || true
                fi
            fi

            # install() used `brew install postgresql@N` (a formula, not a cask).
            "$brew_bin" uninstall --formula "postgresql@${ver}" 2>/dev/null || true

            # Normal uninstall preserves cluster data. The engine exposes this
            # only after its two-flag destructive acknowledgement.
            if [[ "${MESH_PURGE_DATA:-0}" == "1" ]]; then
                local data_dir="${BREW_PREFIX:-/opt/homebrew}/var/postgresql@${ver}"
                case "$data_dir" in
                    "${BREW_PREFIX:-/opt/homebrew}"/var/postgresql@[0-9]*) ;;
                    *) echo "postgresql: refusing unsafe purge path: $data_dir" >&2; return 1 ;;
                esac
                # `target` is L05-allowlisted after the version-scoped guard above.
                local target="$data_dir"
                rm -rf "$target" || return 1
                local service_backup="$HOME/Library/LaunchAgents/homebrew.mxcl.postgresql@${ver}.plist.bak"
                rm -f -- "$service_backup" || return 1
            fi

            # Honest marker drop: success only when the formula is actually gone
            # (mirrors check()'s `brew list --formula` probe; the keg-only binary
            # never lands on PATH, so `command -v postgres` cannot confirm this).
            ! "$brew_bin" list --formula "postgresql@${ver}" >/dev/null 2>&1 \
                && { [[ "${MESH_PURGE_DATA:-0}" != "1" ]] || [[ ! -e "${BREW_PREFIX:-/opt/homebrew}/var/postgresql@${ver}" ]]; }
            ;;

        Linux)
            command -v dpkg >/dev/null 2>&1 || return 0
            command -v apt-get >/dev/null 2>&1 || return 0

            # Disable + stop the systemd unit install() enabled. Cluster name is
            # usually `main`; enumerate via pg_lsclusters (same source install
            # used) so a non-default cluster name is handled too. errexit is off
            # in custom verbs — capture, never `set +e`.
            local cluster clusters_out=""
            if command -v pg_lsclusters >/dev/null 2>&1; then
                clusters_out="$(pg_lsclusters --no-header 2>/dev/null \
                    | awk -v v="$ver" '$1==v {print $2}')"
            fi
            if [[ -z "$clusters_out" ]]; then
                clusters_out="main"
            fi
            while IFS= read -r cluster; do
                [[ -n "$cluster" ]] || continue
                sudo systemctl disable --now "postgresql@${ver}-${cluster}" 2>/dev/null || true
            done <<EOF
$clusters_out
EOF

            # Remove (NOT purge) the version-specific packages install() added.
            # `remove` keeps the cluster data + conf; purge would delete the
            # user's databases. --no-install-recommends mirrors the install side.
            sudo apt-get remove -y -qq \
                "postgresql-${ver}" "postgresql-client-${ver}" 2>/dev/null || true

            # Remove the PGDG apt source + keyring ONLY when no other
            # postgresql-NN major remains installed — the PGDG repo is shared
            # infra that a parallel major (or a future re-install) may still
            # need. Capture dpkg output first, then [[ =~ ]] (pipefail-safe on
            # bash 3.2; no broken-pipe race from `dpkg -l | grep -q`).
            local dpkg_out remaining=0
            dpkg_out="$(dpkg -l 2>/dev/null | awk '/^ii[[:space:]]+postgresql-[0-9]+[[:space:]]/ {print $2}')"
            [[ -n "$dpkg_out" ]] && remaining=1
            if [[ "$remaining" -eq 0 ]]; then
                sudo rm -f \
                    /etc/apt/sources.list.d/pgdg.list \
                    /etc/apt/keyrings/postgresql.gpg 2>/dev/null || true
            fi

            # Honest marker drop: success only when postgresql-N is no longer in
            # the *installed* state. `apt-get remove` (not purge) leaves it in
            # "config-files", for which `dpkg -s` STILL exits 0 — so a bare
            # `! dpkg -s` would never flip and the marker would wrongly survive a
            # real removal. Probe the Status field via dpkg-query (prints
            # "config-files" after remove, "installed" while installed). No pipe →
            # no broken-pipe race.
            local st
            st="$(dpkg-query -W -f='${db:Status-Status}' "postgresql-${ver}" 2>/dev/null || true)"
            [[ "$st" != "installed" ]]
            ;;

        *)
            # Unsupported OS: install() would have hard-stopped here, so there is
            # nothing this verb could have created. Report success (nothing left).
            if [[ "${MESH_PURGE_DATA:-0}" == "1" ]]; then
                [[ ! -e "$HOME/Library/LaunchAgents/homebrew.mxcl.postgresql@${ver}.plist.bak" ]] || return 1
            fi
            return 0
            ;;
    esac
}
