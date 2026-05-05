#!/usr/bin/env bash
# install-postgres.sh — PostgreSQL server install + service start +
# auto role/db for $USER. Opt-in piece of 60-web-stack, gated by
# INCLUDE_POSTGRES=1 (set via the menu or env).
#
# What this script does (idempotent top to bottom):
#   1. Resolves POSTGRES_VERSION (default 17). If a different major is
#      already installed, warns and skips reinstall — auto-migration is
#      out of scope.
#   2. Installs PostgreSQL:
#        Mac      → brew install postgresql@${POSTGRES_VERSION}
#        Linux    → PGDG APT repo (apt.postgresql.org) + apt install
#                   postgresql-${POSTGRES_VERSION}
#   3. Pre-flight port :5432 conflict check. Owner != postgres → emit
#      followup and skip launching service (mirrors web-stack-port-conflict
#      pattern for nginx :80).
#   4. Starts the service:
#        Mac canonical prefix → brew services start
#        Mac custom prefix     → launch_wrapper_install_extbrew (TCC-safe;
#                                see feedback_tcc_entitlement_spawn_only.md)
#        Linux                 → systemctl enable+start
#   5. Waits up to 15s for the socket to be live (pg_isready).
#   6. Auto-creates role and database for $USER, but ONLY when both are
#      absent. Pristine-guard: if the role already exists, skip both —
#      this preserves any custom setup the user did manually.
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
source "$HERE/../../../lib/log.sh"
# shellcheck disable=SC1091
source "$HERE/../../../lib/launch-wrapper.sh"

POSTGRES_VERSION="${POSTGRES_VERSION:-17}"

# Validate the version looks like a major number (1-3 digits). Stops a
# typo'd POSTGRES_VERSION from cascading into apt/brew with cryptic
# errors deep in the install.
if [[ ! "$POSTGRES_VERSION" =~ ^[0-9]{1,3}$ ]]; then
    fail "POSTGRES_VERSION='$POSTGRES_VERSION' is not a valid major version (expected like 16, 17)"
fi

OS=""
case "$(uname -s)" in
    Darwin) OS="mac" ;;
    Linux)  OS="$(grep -qi microsoft /proc/version 2>/dev/null && echo wsl || echo linux)" ;;
    *)      fail "unsupported OS"; exit 1 ;;
esac

# ─── Helpers ─────────────────────────────────────────────────────────

# Detect whether ANY postgres major is already installed on this host.
# Returns the detected version (e.g. "16", "17") on stdout, empty if none.
_postgres_installed_version() {
    case "$OS" in
        mac)
            : "${BREW_BIN:?BREW_BIN not set}"
            # Find any postgresql@<v> formula installed via brew.
            "$BREW_BIN" list --formula 2>/dev/null \
                | awk -F'@' '/^postgresql@[0-9]+$/ {print $2; exit}'
            ;;
        wsl|linux)
            # Find postgresql-<v> via dpkg (matches PGDG APT pattern).
            dpkg -l 2>/dev/null | awk '/^ii\s+postgresql-[0-9]+\s/ {
                split($2, a, "-"); print a[2]; exit }'
            ;;
    esac
}

# Returns 0 if port :5432 has a listener owned by postgres, 1 otherwise.
# Used to short-circuit role/db creation when the listener is foreign.
_port_5432_owner_is_postgres() {
    case "$OS" in
        mac)
            local owner
            owner=$(lsof -nP -iTCP:5432 -sTCP:LISTEN 2>/dev/null \
                | awk 'NR==2 {print $1; exit}')
            [[ "$owner" == "postgres" ]]
            ;;
        wsl|linux)
            ss -ltnp 'sport = :5432' 2>/dev/null | grep -q '"postgres"'
            ;;
    esac
}

# Returns 0 if anything other than postgres listens on :5432.
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
            [[ -n "$line" ]] && ! echo "$line" | grep -q '"postgres"'
            ;;
    esac
}

# Wait up to ${1:-15} seconds for postgres to accept connections on :5432.
_wait_postgres_ready() {
    local timeout="${1:-15}"
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

# Resolve the brew-bin path for postgres on this machine. Used both for
# `brew services start` and (in custom-prefix mode) as the wrapped binary
# for launch_wrapper_install_extbrew.
_pg_brew_path() {
    : "${BREW_PREFIX:?BREW_PREFIX not set}"
    echo "$BREW_PREFIX/opt/postgresql@${POSTGRES_VERSION}/bin/postgres"
}

# ─── 1 · Detect existing install (cross-major guard) ─────────────────
existing_pg_ver="$(_postgres_installed_version || true)"
if [[ -n "$existing_pg_ver" ]] && [[ "$existing_pg_ver" != "$POSTGRES_VERSION" ]]; then
    warn "PostgreSQL ${existing_pg_ver} already installed; requested ${POSTGRES_VERSION} — skipping install"
    warn "  to migrate: 1) pg_dumpall > backup.sql 2) uninstall pg${existing_pg_ver} 3) re-run with POSTGRES_VERSION=${POSTGRES_VERSION} 4) psql < backup.sql"
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
            if [[ ! -f "$KEYRING" ]]; then
                info "adding PostgreSQL Global Development Group GPG keyring"
                sudo install -d -m 0755 /etc/apt/keyrings
                curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
                    | sudo gpg --dearmor -o "$KEYRING"
            fi
            if [[ ! -f "$SOURCES_LIST" ]]; then
                # shellcheck disable=SC1091
                . /etc/os-release    # provides VERSION_CODENAME
                info "adding PGDG APT source for ${VERSION_CODENAME}"
                echo "deb [signed-by=$KEYRING] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
                    | sudo tee "$SOURCES_LIST" > /dev/null
                sudo apt-get update -qq
            fi
            sudo apt-get install -y -qq --no-install-recommends \
                "postgresql-${POSTGRES_VERSION}" \
                "postgresql-client-${POSTGRES_VERSION}"
            ;;
    esac
    ok "postgresql@${POSTGRES_VERSION} installed"
else
    ok "postgresql@${POSTGRES_VERSION} already installed"
fi

# ─── 2 · Pre-flight port :5432 conflict ──────────────────────────────
PORT_CONFLICT=0
if _port_5432_in_foreign_use; then
    PORT_CONFLICT=1
    case "$OS" in
        mac)
            owner=$(lsof -nP -iTCP:5432 -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1}')
            warn "port 5432 is held by '$owner' — skipping postgres service start"
            warn "  if '$owner' is Postgres.app / EDB installer, stop it before re-running"
            ;;
        wsl|linux)
            warn "port 5432 is in foreign use — skipping postgres service start"
            warn "  inspect with: sudo ss -tlnp 'sport = :5432'"
            ;;
    esac
fi

# ─── 3 · Start the service ───────────────────────────────────────────
if [[ "$PORT_CONFLICT" == "1" ]]; then
    : # skipped — port is foreign-owned
elif _port_5432_owner_is_postgres; then
    ok "postgres already listening on :5432"
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
                # TCC sandbox exit 78. Wrap via rootfs shim. Cluster data
                # lives at $BREW_PREFIX/var/postgresql@${POSTGRES_VERSION}.
                info "starting postgres via launch-wrapper (custom BREW_PREFIX = $BREW_PREFIX)"
                launch_wrapper_install_extbrew \
                    --svc "postgresql@${POSTGRES_VERSION}" \
                    --label "com.${USER}.postgresql@${POSTGRES_VERSION}" \
                    --brew-bin "$(_pg_brew_path)" \
                    --workdir "$BREW_PREFIX/var/postgresql@${POSTGRES_VERSION}" \
                    --env LC_ALL=en_US.UTF-8 \
                    -- -D "$BREW_PREFIX/var/postgresql@${POSTGRES_VERSION}" \
                    || warn "launch-wrapper for postgres failed (non-fatal — start manually)"
            else
                info "starting postgres via brew services"
                "$BREW_BIN" services start "postgresql@${POSTGRES_VERSION}" >/dev/null 2>&1 \
                    || warn "brew services start postgresql@${POSTGRES_VERSION} failed"
            fi
            ;;
        wsl|linux)
            # WSL without systemd needs a different path; detect first.
            if ! systemctl is-system-running --quiet 2>/dev/null \
               && ! systemctl --version >/dev/null 2>&1; then
                warn "systemd not active — start postgres manually:"
                warn "  sudo pg_ctlcluster ${POSTGRES_VERSION} main start"
            else
                info "enabling + starting postgresql service"
                sudo systemctl enable "postgresql@${POSTGRES_VERSION}-main" >/dev/null 2>&1 || true
                sudo systemctl enable postgresql >/dev/null 2>&1 || true
                sudo systemctl start "postgresql@${POSTGRES_VERSION}-main" 2>/dev/null \
                    || sudo systemctl start postgresql 2>/dev/null \
                    || warn "systemctl start postgresql failed — try: sudo pg_ctlcluster ${POSTGRES_VERSION} main start"
            fi
            ;;
    esac
fi

# ─── 4 · Wait for socket + pristine-only role/db creation ────────────
if [[ "$PORT_CONFLICT" == "1" ]]; then
    warn "skipping role/db setup — service was not started"
elif _wait_postgres_ready 15; then
    case "$OS" in
        mac)
            # Mac brew default: trust local + auto-creates `$USER` superuser
            # on first start. Idempotent createuser/createdb anyway.
            if ! psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$USER'" postgres 2>/dev/null | grep -q '^1$'; then
                info "creating role '$USER' (superuser)"
                createuser -s "$USER" 2>/dev/null \
                    || warn "createuser '$USER' failed (may already exist)"
            else
                ok "role '$USER' already exists"
            fi
            if ! psql -tAc "SELECT 1 FROM pg_database WHERE datname='$USER'" postgres 2>/dev/null | grep -q '^1$'; then
                info "creating database '$USER'"
                createdb "$USER" 2>/dev/null \
                    || warn "createdb '$USER' failed (may already exist)"
            else
                ok "database '$USER' already exists"
            fi
            ;;
        wsl|linux)
            # apt default: cluster owned by 'postgres' OS user, peer auth.
            # We need sudo -u postgres for admin work. Pristine-guard:
            # only create role + db when role doesn't yet exist.
            if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$USER'" 2>/dev/null | grep -q '^1$'; then
                info "creating role '$USER' (superuser, peer-auth)"
                sudo -u postgres createuser -s "$USER" \
                    || warn "createuser '$USER' failed"
                info "creating database '$USER'"
                sudo -u postgres createdb -O "$USER" "$USER" \
                    || warn "createdb '$USER' failed"
            else
                ok "role '$USER' already exists — skipping pristine setup"
            fi
            ;;
    esac
else
    warn "postgres did not become ready within 15s — role/db setup skipped"
    warn "  inspect: pg_isready -h 127.0.0.1 -p 5432"
fi

# ─── 5 · Done ────────────────────────────────────────────────────────
ok "PostgreSQL ${POSTGRES_VERSION} ready:"
ok "  socket:  127.0.0.1:5432"
ok "  role:    $USER (superuser)"
ok "  db:      $USER"
ok "  Laravel .env:"
ok "    DB_CONNECTION=pgsql DB_HOST=127.0.0.1 DB_PORT=5432"
ok "    DB_DATABASE=$USER DB_USERNAME=$USER DB_PASSWORD="
