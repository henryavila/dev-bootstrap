#!/usr/bin/env bash
# install-postgres.sh — PostgreSQL server install + service start +
# auto role/db for $USER. Opt-in piece of 60-web-stack, gated by
# INCLUDE_POSTGRES=1 (set via the menu or env).
#
# What this script does (idempotent top to bottom):
#   1. Validates inputs hard (POSTGRES_VERSION numeric, $USER safe for
#      role/db naming).
#   2. Resolves POSTGRES_VERSION (default 17). If a different major is
#      already installed and the user EXPLICITLY requested another, hard
#      stops with a `followup critical`. Auto-downgrade is never silent.
#   3. Detects parallel-major installs (e.g. pg16 AND pg17 both present)
#      and hard stops — port 5432 can only serve one cluster at a time.
#   4. Installs PostgreSQL:
#        Mac      → brew install postgresql@${POSTGRES_VERSION}
#        Linux    → PGDG APT repo (apt.postgresql.org) + apt install
#                   postgresql-${POSTGRES_VERSION}
#   5. Pre-flight port :5432 conflict check. Owner != postgres → emit
#      `followup critical` and skip launching service AND role/db setup.
#   6. Starts the service (capture stderr; on failure → rollback +
#      `followup critical` + exit):
#        Mac canonical prefix → brew services start
#        Mac custom prefix     → launch_wrapper_install_extbrew (TCC-safe;
#                                rootfs wrapper preserves entitlement across execve)
#        Linux                 → pg_lsclusters detection + systemctl;
#                                WSL-without-systemd path is explicit.
#   7. Waits up to 30s for the socket to be live (pg_isready). Failure
#      → `followup critical`.
#   8. Pristine-guards role and database creation INDEPENDENTLY: only
#      missing pieces are created. Stderr from createuser/createdb is
#      surfaced — no "may already exist" lies.
#   9. Final "ready" banner gated on PG_READY flag — never claims success
#      when an upstream step failed.
#
# Connection from Laravel .env:
#   DB_CONNECTION=pgsql
#   DB_HOST=127.0.0.1
#   DB_PORT=5432
#   DB_DATABASE=<user>            # default DB created here
#   DB_USERNAME=<user>            # superuser role created here
#   DB_PASSWORD=                  # peer/trust local auth — empty is fine

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../../scripts/lib/log.sh"
# shellcheck disable=SC1091
source "$HERE/../../../scripts/lib/launch-wrapper.sh"

# T-006: apply postgres boot-state from the per-host services.default via the
# shared services lib (svc_enable/svc_disable) instead of forcing `enable` at
# install. Isolated subshell (the lib sets `set -uo pipefail`) + best-effort.
_apply_boot_state() {
    local recon="$HERE/../../../scripts/lib/services/reconcile.sh"
    [[ -f "$recon" ]] || return 0
    ( . "$recon" && services_reconcile_one "$1" ) 2>/dev/null || true
}

# ─── 1 · Capture caller intent before defaulting ─────────────────────
# POSTGRES_VERSION_REQUESTED is set ONLY when the caller passed it via
# env or menu; empty when we fall back to the default. Cross-major
# detection (step 3) treats explicit-vs-default differently: an explicit
# request that collides with an existing different major MUST hard-stop;
# a silent default fall-through is allowed to defer.
POSTGRES_VERSION_REQUESTED="${POSTGRES_VERSION:-}"
POSTGRES_VERSION="${POSTGRES_VERSION:-17}"

# Numeric major version, plausibly a real PG release (10-29 covers
# everything from PG10 in 2017 to comfortably future-proofed). Reject
# anything outside that band — "17.2", "latest", "12; rm -rf /", etc.
if [[ ! "$POSTGRES_VERSION" =~ ^(1[0-9]|2[0-9])$ ]]; then
    fail "POSTGRES_VERSION='$POSTGRES_VERSION' invalid — supported majors: 10-29 (e.g. 16, 17)"
    exit 1
fi

# ─── 2 · Sanitize $USER for role/db naming ───────────────────────────
# We interpolate $USER into psql -tAc queries below. Postgres identifier
# rules + a defense-in-depth filter: alphanumeric, underscore, hyphen,
# starts with letter/underscore, max 31 chars (PG NAMEDATALEN-1). On
# real machines $USER is benign; this guards against env-var surprises
# in containers, CI, and exotic LDAP setups where $USER could carry
# spaces, quotes, or worse.
if [[ ! "$USER" =~ ^[a-zA-Z_][a-zA-Z0-9_-]{0,30}$ ]]; then
    fail "refusing to use suspicious USER='$USER' as PostgreSQL role/db name (expected ^[a-zA-Z_][a-zA-Z0-9_-]{0,30}\$)"
    exit 1
fi

# ─── 3 · OS detection + Linux distro sanity check ────────────────────
OS=""
case "$(uname -s)" in
    Darwin) OS="mac" ;;
    Linux)  OS="$(grep -qi microsoft /proc/version 2>/dev/null && echo wsl || echo linux)" ;;
    *)      fail "unsupported OS"; exit 1 ;;
esac

# Linux branch needs apt + dpkg. The bootstrap doesn't claim to support
# non-Debian distros today, but a user could call this script directly.
case "$OS" in
    wsl|linux)
        if ! command -v dpkg >/dev/null 2>&1 || ! command -v apt-get >/dev/null 2>&1; then
            distro="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
            followup critical "install-postgres.sh requires Debian/Ubuntu (apt + dpkg). Detected: $distro"
            exit 1
        fi
        ;;
esac

# ─── Helpers ─────────────────────────────────────────────────────────

# Print every installed postgres major, one per line. Empty output
# means none. Caller decides what "more than one" means.
_postgres_installed_versions() {
    case "$OS" in
        mac)
            : "${BREW_BIN:?BREW_BIN not set}"
            "$BREW_BIN" list --formula 2>/dev/null \
                | awk -F'@' '/^postgresql@[0-9]+$/ {print $2}'
            ;;
        wsl|linux)
            dpkg -l 2>/dev/null \
                | awk '/^ii\s+postgresql-[0-9]+\s/ { split($2, a, "-"); print a[2] }'
            ;;
    esac
}

# Returns 0 if anything other than postgres listens on :5432. Mac uses
# lsof's process column; Linux/WSL first uses ss process metadata when
# available, then falls back to pg_isready because unprivileged ss can omit
# the Process column even for the real postgres listener.
_port_5432_in_foreign_use() {
    case "$OS" in
        mac)
            local owner
            owner=$(lsof -nP -iTCP:5432 -sTCP:LISTEN 2>/dev/null \
                | awk 'NR==2 {print $1; exit}')
            [[ -n "$owner" ]] && [[ "$owner" != "postgres" ]]
            ;;
        wsl|linux)
            local line
            line=$(ss -ltnp 'sport = :5432' 2>/dev/null | awk 'NR==2')
            [[ -z "$line" ]] && return 1
            echo "$line" | grep -q '"postgres"' && return 1
            pg_isready -h 127.0.0.1 -p 5432 2>/dev/null | grep -q 'accepting connections' && return 1
            pg_isready -h 127.0.0.1 -p 5432 2>/dev/null | grep -q 'no response' && return 0
            return 0
            ;;
    esac
}

# Returns 0 if :5432 has a listener and it IS postgres.
_port_5432_owner_is_postgres() {
    case "$OS" in
        mac)
            local owner
            owner=$(lsof -nP -iTCP:5432 -sTCP:LISTEN 2>/dev/null \
                | awk 'NR==2 {print $1; exit}')
            [[ "$owner" == "postgres" ]]
            ;;
        wsl|linux)
            ss -ltnp 'sport = :5432' 2>/dev/null | grep -q '"postgres"' \
                || pg_isready -h 127.0.0.1 -p 5432 2>/dev/null | grep -q 'accepting connections'
            ;;
    esac
}

# Wait up to ${1:-30} seconds for postgres to accept connections on
# :5432. 30s default tolerates cold systemd start + first-time initdb
# on a slow disk.
_wait_postgres_ready() {
    local timeout="${1:-30}"
    local i=0
    while [[ $i -lt $timeout ]]; do
        if pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

_pg_brew_path() {
    : "${BREW_PREFIX:?BREW_PREFIX not set}"
    echo "$BREW_PREFIX/opt/postgresql@${POSTGRES_VERSION}/bin/postgres"
}

_pg_data_dir() {
    : "${BREW_PREFIX:?BREW_PREFIX not set}"
    echo "$BREW_PREFIX/var/postgresql@${POSTGRES_VERSION}"
}

_ensure_mac_pg_data_dir() {
    local data_dir="$1"
    local initdb_bin initdb_err existing_entry

    if [[ -f "$data_dir/PG_VERSION" ]]; then
        return 0
    fi

    if [[ -e "$data_dir" && ! -d "$data_dir" ]]; then
        followup critical "$data_dir exists but is not a directory. PostgreSQL data directory cannot be initialized safely."
        return 1
    fi

    existing_entry=""
    if [[ -d "$data_dir" ]]; then
        existing_entry="$(find "$data_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"
    fi
    if [[ -n "$existing_entry" ]]; then
        followup critical "$data_dir exists but is not an initialized PostgreSQL data directory (missing PG_VERSION). Refusing to run initdb over existing content; move it aside or restore the cluster, then re-run."
        return 1
    fi

    initdb_bin="$BREW_PREFIX/opt/postgresql@${POSTGRES_VERSION}/bin/initdb"
    if [[ ! -x "$initdb_bin" ]]; then
        followup critical "initdb not found for postgresql@${POSTGRES_VERSION}: $initdb_bin"
        return 1
    fi

    info "initializing PostgreSQL data directory $data_dir"
    initdb_err=""
    if ! initdb_err="$(LC_ALL=en_US.UTF-8 "$initdb_bin" --locale=en_US.UTF-8 -E UTF-8 "$data_dir" 2>&1)"; then
        followup critical "initdb for postgresql@${POSTGRES_VERSION} failed: $initdb_err"
        return 1
    fi
    ok "PostgreSQL data directory initialized at $data_dir"
}

# Detect "is systemd actually running as PID 1?" — more reliable than
# `systemctl is-system-running` which returns "offline" on WSL but
# `--version` succeeds because the binary is present.
_systemd_is_pid1() {
    [[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" == "systemd" ]]
}

# ─── 4 · Cross-major detection ───────────────────────────────────────
# Collect ALL installed majors. Parallel installs (pg16 AND pg17 both
# present) are unsupported by this script — port 5432 can only serve
# one cluster at a time, and silently picking one would orphan the
# other.
existing_majors=()
while IFS= read -r maj; do
    [[ -n "$maj" ]] && existing_majors+=("$maj")
done < <(_postgres_installed_versions || true)

if [[ "${#existing_majors[@]}" -gt 1 ]]; then
    followup critical "Multiple PostgreSQL majors installed: ${existing_majors[*]}. Bootstrap will not auto-pick one — port 5432 can only serve one cluster at a time. Decide: pg_dumpall the one you want to keep, then purge the others, then re-run."
    exit 1
fi

existing_pg_ver="${existing_majors[0]:-}"

if [[ -n "$existing_pg_ver" ]] && [[ "$existing_pg_ver" != "$POSTGRES_VERSION" ]]; then
    if [[ -n "$POSTGRES_VERSION_REQUESTED" ]]; then
        # User explicitly asked for a version that conflicts with what's
        # installed. Auto-downgrading would silently subvert their request.
        followup critical "Requested PostgreSQL ${POSTGRES_VERSION} but ${existing_pg_ver} is already installed. Bootstrap will not auto-downgrade. Choose: (a) keep existing — re-run with POSTGRES_VERSION=${existing_pg_ver}; or (b) migrate — pg_dumpall, uninstall pg${existing_pg_ver}, re-run with POSTGRES_VERSION=${POSTGRES_VERSION}."
        exit 1
    fi
    # Silent default fall-through: caller didn't insist on 17, host has
    # 16 — keep using 16. Inform but don't escalate.
    info "PostgreSQL ${existing_pg_ver} already installed; defaulting to it (no POSTGRES_VERSION requested)"
    POSTGRES_VERSION="$existing_pg_ver"
elif [[ -z "$existing_pg_ver" ]]; then
    info "installing postgresql@${POSTGRES_VERSION}"
    case "$OS" in
        mac)
            : "${BREW_BIN:?BREW_BIN not set}"
            "$BREW_BIN" install "postgresql@${POSTGRES_VERSION}"
            ;;
        wsl|linux)
            # PGDG repo: apt.postgresql.org/pub/repos/apt — gives us
            # postgresql-N for every supported major, vs Ubuntu's
            # universe which usually pins one major behind.
            KEYRING="/etc/apt/keyrings/postgresql.gpg"
            SOURCES_LIST="/etc/apt/sources.list.d/pgdg.list"

            # Atomic keyring write: tempfile → mv. A previous run that
            # crashed mid-write (network reset, signal, gpg crash) would
            # otherwise leave a corrupt keyring file, and our `[[ ! -f ]]`
            # guard would skip re-creation forever — apt-get update then
            # fails on signature verification with no recovery hint.
            # Verify content with `gpg --show-keys` before declaring it good.
            need_keyring=0
            if [[ ! -s "$KEYRING" ]] \
               || ! sudo gpg --show-keys "$KEYRING" >/dev/null 2>&1; then
                need_keyring=1
            fi
            if [[ "$need_keyring" == "1" ]]; then
                info "writing PGDG GPG keyring atomically"
                sudo install -d -m 0755 /etc/apt/keyrings
                tmp_key=$(sudo mktemp)
                if ! curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
                        | sudo gpg --dearmor -o "$tmp_key"; then
                    sudo rm -f "$tmp_key"
                    followup critical "failed to fetch+dearmor PGDG GPG key — inspect network and curl/gpg availability"
                    exit 1
                fi
                sudo mv "$tmp_key" "$KEYRING"
                sudo chmod 0644 "$KEYRING"
            fi

            if [[ ! -f "$SOURCES_LIST" ]]; then
                # shellcheck disable=SC1091
                . /etc/os-release    # provides VERSION_CODENAME
                info "adding PGDG APT source for ${VERSION_CODENAME}"
                echo "deb [signed-by=$KEYRING] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
                    | sudo tee "$SOURCES_LIST" > /dev/null
            fi

            # Always update; cheap insurance against partial state where
            # keyring was just renewed but cache wasn't refreshed.
            sudo apt-get update -qq

            apt_err=""
            if ! apt_err="$(sudo apt-get install -y -qq --no-install-recommends \
                    "postgresql-${POSTGRES_VERSION}" \
                    "postgresql-client-${POSTGRES_VERSION}" 2>&1 1>/dev/null)"; then
                # shellcheck disable=SC1091
                . /etc/os-release 2>/dev/null
                followup critical "apt-get install postgresql-${POSTGRES_VERSION} failed on ${VERSION_CODENAME:-unknown}. Apt error: ${apt_err}. Diagnose: apt-cache madison postgresql-${POSTGRES_VERSION}. PGDG codename support: https://wiki.postgresql.org/wiki/Apt"
                exit 1
            fi
            ;;
    esac
    ok "postgresql@${POSTGRES_VERSION} installed"
else
    ok "postgresql@${POSTGRES_VERSION} already installed"
fi

pg_data_dir=""
if [[ "$OS" == "mac" ]]; then
    pg_data_dir="$(_pg_data_dir)"
    if ! _ensure_mac_pg_data_dir "$pg_data_dir"; then
        exit 1
    fi
fi

# ─── 5 · Pre-flight port :5432 conflict ──────────────────────────────
PORT_CONFLICT=0
if _port_5432_in_foreign_use; then
    PORT_CONFLICT=1
    case "$OS" in
        mac)
            owner=$(lsof -nP -iTCP:5432 -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1; exit}')
            followup critical "port 5432 held by '$owner' — postgres service NOT started, role/db NOT created. Stop '$owner' (Postgres.app / EDB / etc.) and re-run."
            ;;
        wsl|linux)
            followup critical "port 5432 in foreign use — postgres service NOT started, role/db NOT created. Inspect: sudo ss -tlnp 'sport = :5432'"
            ;;
    esac
fi

# ─── 6 · Start the service ───────────────────────────────────────────
SERVICE_STARTED=0
if [[ "$PORT_CONFLICT" == "1" ]]; then
    : # skipped — port is foreign-owned (followup already emitted)
elif _port_5432_owner_is_postgres; then
    ok "postgres already listening on :5432"
    SERVICE_STARTED=1
else
    case "$OS" in
        mac)
            : "${BREW_PREFIX:?BREW_PREFIX not set}"
            case "$BREW_PREFIX" in
                /opt/homebrew|/usr/local) pg_use_wrapper=0 ;;
                *)                        pg_use_wrapper=1 ;;
            esac

            if [[ "$pg_use_wrapper" == "1" ]]; then
                # Custom prefix → user-scope LaunchAgent in /Volumes/* hits
                # TCC sandbox exit 78. Wrap via rootfs shim.
                info "starting postgres via launch-wrapper (custom BREW_PREFIX = $BREW_PREFIX)"
                pg_label="com.${USER}.postgresql@${POSTGRES_VERSION}"
                pg_brew_plist="$LAUNCH_WRAPPER_PLIST_DIR/homebrew.mxcl.postgresql@${POSTGRES_VERSION}.plist"

                if launch_wrapper_install_extbrew \
                        --svc "postgresql@${POSTGRES_VERSION}" \
                        --label "$pg_label" \
                        --brew-bin "$(_pg_brew_path)" \
                        --workdir "$pg_data_dir" \
                        --env LC_ALL=en_US.UTF-8 \
                        -- -D "$pg_data_dir"; then
                    SERVICE_STARTED=1
                else
                    # Wrapper failed AFTER having renamed the brew plist
                    # to .bak and written a new one. Roll back: tear down
                    # the wrapper plist + restore the brew one — leaves
                    # the user with the same state they started in, plus
                    # an actionable followup.
                    launch_wrapper_teardown "$pg_label" || true
                    [[ -f "${pg_brew_plist}.bak" ]] && mv "${pg_brew_plist}.bak" "$pg_brew_plist"
                    followup critical "launch-wrapper for postgresql@${POSTGRES_VERSION} failed. State rolled back to brew-managed plist. If you saw exit 78 / TCC denial, see launch-wrapper.sh for the TCC workaround"
                    exit 1
                fi
            else
                brew_err=""
                if ! brew_err="$("$BREW_BIN" services start "postgresql@${POSTGRES_VERSION}" 2>&1 1>/dev/null)"; then
                    followup critical "brew services start postgresql@${POSTGRES_VERSION} failed. Output: ${brew_err}"
                    exit 1
                fi
                SERVICE_STARTED=1
            fi
            ;;
        wsl|linux)
            if ! _systemd_is_pid1; then
                followup manual "systemd not running as PID 1 (WSL without systemd?). Start postgres manually each session: sudo pg_ctlcluster ${POSTGRES_VERSION} main start. Enable systemd in WSL: https://learn.microsoft.com/windows/wsl/systemd"
            else
                # Detect existing clusters via pg_lsclusters (ships in
                # postgresql-common, an autodep of postgresql-N). Picking
                # the right unit name matters: PGDG packages emit
                # postgresql@N-<cluster>.service. Default cluster is
                # `main`; multi-cluster hosts may have others.
                clusters=()
                if command -v pg_lsclusters >/dev/null 2>&1; then
                    while IFS= read -r cl; do
                        [[ -n "$cl" ]] && clusters+=("$cl")
                    done < <(pg_lsclusters --no-header 2>/dev/null \
                        | awk -v v="$POSTGRES_VERSION" '$1==v {print $2}')
                fi

                if [[ "${#clusters[@]}" -eq 0 ]]; then
                    followup critical "PostgreSQL ${POSTGRES_VERSION} package installed but no cluster exists. Create one: sudo pg_createcluster ${POSTGRES_VERSION} main --start"
                    exit 1
                fi

                cluster="${clusters[0]}"
                unit="postgresql@${POSTGRES_VERSION}-${cluster}"

                # T-006: install no longer force-enables the unit at boot. Start
                # it for the role/db setup below, then reconcile its boot-state
                # from the per-host services.default via the shared services lib
                # (svc_enable/svc_disable) — installed ≠ auto-enabled.
                start_err=""
                if ! start_err="$(sudo systemctl start "$unit" 2>&1)"; then
                    followup critical "systemctl start $unit failed: $start_err. Diagnose: sudo journalctl -u $unit -n 50"
                    exit 1
                fi
                SERVICE_STARTED=1
                _apply_boot_state postgres
            fi
            ;;
    esac
fi

# ─── 7 · Wait for socket + pristine-only role/db creation ────────────
PG_READY=0
if [[ "$PORT_CONFLICT" == "1" ]] || [[ "$SERVICE_STARTED" == "0" ]]; then
    warn "skipping role/db setup — service was not started"
elif _wait_postgres_ready 30; then
    case "$OS" in
        mac)
            # Mac: brew default = trust local. Connect to `template1`
            # (always present, vs `postgres` which a stock brew install
            # may not have) to query meta tables.
            role_err=""
            if ! psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$USER'" template1 2>/dev/null | grep -q '^1$'; then
                info "creating role '$USER' (superuser)"
                if ! role_err="$(createuser -s "$USER" 2>&1)"; then
                    followup critical "createuser '$USER' failed: $role_err. Diagnose: psql -h 127.0.0.1 template1 -c '\\du'"
                    exit 1
                fi
            else
                ok "role '$USER' already exists"
            fi

            db_err=""
            if ! psql -tAc "SELECT 1 FROM pg_database WHERE datname='$USER'" template1 2>/dev/null | grep -q '^1$'; then
                info "creating database '$USER'"
                if ! db_err="$(createdb "$USER" 2>&1)"; then
                    followup critical "createdb '$USER' failed: $db_err"
                    exit 1
                fi
            else
                ok "database '$USER' already exists"
            fi
            PG_READY=1
            ;;
        wsl|linux)
            # Linux: peer auth — admin DDL requires `sudo -u postgres`.
            # Role and database are checked INDEPENDENTLY (mirrors the
            # Mac path); previously this block created both inside one
            # `if !`, so a half-applied state (role created, db missing)
            # was never repaired on re-run.
            role_err=""
            if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$USER'" 2>/dev/null | grep -q '^1$'; then
                info "creating role '$USER' (superuser, peer-auth)"
                if ! role_err="$(sudo -u postgres createuser -s "$USER" 2>&1)"; then
                    followup critical "createuser '$USER' failed: $role_err. Diagnose: sudo -u postgres psql -c '\\du'"
                    exit 1
                fi
            else
                ok "role '$USER' already exists"
            fi

            db_err=""
            if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$USER'" 2>/dev/null | grep -q '^1$'; then
                info "creating database '$USER'"
                if ! db_err="$(sudo -u postgres createdb -O "$USER" "$USER" 2>&1)"; then
                    followup critical "createdb '$USER' failed: $db_err"
                    exit 1
                fi
            else
                ok "database '$USER' already exists"
            fi
            PG_READY=1
            ;;
    esac
else
    followup critical "postgres did not become ready within 30s — role/db setup skipped. Inspect: pg_isready -h 127.0.0.1 -p 5432. Mac: brew services list | grep postgresql. Linux: sudo systemctl status postgresql@${POSTGRES_VERSION}-main"
fi

# ─── 8 · Done banner — only when everything succeeded ────────────────
if [[ "$PG_READY" == "1" ]]; then
    ok "PostgreSQL ${POSTGRES_VERSION} ready:"
    ok "  socket:  127.0.0.1:5432"
    ok "  role:    $USER (superuser)"
    ok "  db:      $USER"
    ok "  Laravel .env:"
    ok "    DB_CONNECTION=pgsql DB_HOST=127.0.0.1 DB_PORT=5432"
    ok "    DB_DATABASE=$USER DB_USERNAME=$USER DB_PASSWORD="
else
    warn "PostgreSQL ${POSTGRES_VERSION} install completed but not fully usable — see followup summary at end of bootstrap"
    exit 1
fi
