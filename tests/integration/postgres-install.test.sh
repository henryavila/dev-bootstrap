#!/usr/bin/env bash
# tests/integration/postgres-install.test.sh
#
# Regression coverage for the INCLUDE_POSTGRES opt-in (60-web-stack).
#
# This is a CONTRACT test: it asserts that the install script + menu +
# install.{mac,wsl}.sh wiring all carry the load-bearing pieces. It does
# NOT actually install postgres (CI containers don't have systemd; Mac
# runners would mutate brew state). Functional validation lives on the
# host where the bootstrap ran.
#
# Patterns checked:
#   1. install-postgres.sh exists, is executable, has valid bash syntax
#   2. POSTGRES_VERSION default + numeric-validation guard
#   3. Cross-major detection — warns when wrong major already installed
#   4. Port :5432 conflict detection (lsof on Mac, ss on Linux)
#   5. Pristine-only role/db creation (psql query before createuser)
#   6. Mac: launch_wrapper_install_extbrew sourced + invoked
#   7. Linux: PGDG APT repo + signed-by keyring + --no-install-recommends
#   8. Linux: sudo -u postgres for admin DDL
#   9. install.mac.sh + install.wsl.sh wire INCLUDE_POSTGRES
#  10. lib/menu.sh: postgres item in extras checklist + case map +
#      POSTGRES_VERSION prompt (gated on INCLUDE_POSTGRES=1)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

PG_SCRIPT="$ROOT/topics/60-web-stack/scripts/install-postgres.sh"
MAC_INSTALL="$ROOT/topics/60-web-stack/install.mac.sh"
WSL_INSTALL="$ROOT/topics/60-web-stack/install.wsl.sh"
MENU="$ROOT/lib/menu.sh"

assert_pattern_present() {
    local file="$1" pattern="$2" msg="$3"
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' not found in $file)"
    fi
}

echo
echo "═══ install-postgres.sh — file-level invariants ═══"

assert_file_exists "$PG_SCRIPT" "install-postgres.sh exists"

if [[ -x "$PG_SCRIPT" ]]; then
    pass "install-postgres.sh is executable"
else
    fail "install-postgres.sh is not executable"
fi

if bash -n "$PG_SCRIPT" 2>/dev/null; then
    pass "install-postgres.sh has valid bash syntax"
else
    fail "install-postgres.sh — bash -n failed"
fi

echo
echo "═══ POSTGRES_VERSION resolution + validation ═══"

assert_pattern_present "$PG_SCRIPT" 'POSTGRES_VERSION="\$\{POSTGRES_VERSION:-17\}"' \
    "POSTGRES_VERSION default = 17"

assert_pattern_present "$PG_SCRIPT" '\[\[ ! "\$POSTGRES_VERSION" =~ \^\[0-9\]' \
    "POSTGRES_VERSION numeric-validation guard"

echo
echo "═══ Cross-major detection (don't auto-replace existing install) ═══"

assert_pattern_present "$PG_SCRIPT" '_postgres_installed_version' \
    "helper to detect existing postgres major"

assert_pattern_present "$PG_SCRIPT" 'requested.*skipping install' \
    "warns + skips when wrong major already installed"

echo
echo "═══ Port :5432 conflict detection ═══"

assert_pattern_present "$PG_SCRIPT" 'lsof -nP -iTCP:5432' \
    "Mac: lsof inspects :5432 owner"

assert_pattern_present "$PG_SCRIPT" "ss -ltnp 'sport = :5432'" \
    "Linux: ss inspects :5432 owner"

assert_pattern_present "$PG_SCRIPT" '_port_5432_in_foreign_use' \
    "foreign-owner detection function"

assert_pattern_present "$PG_SCRIPT" 'PORT_CONFLICT=1' \
    "sets PORT_CONFLICT flag to skip service start"

echo
echo "═══ Pristine-only role/db creation ═══"

assert_pattern_present "$PG_SCRIPT" "SELECT 1 FROM pg_roles WHERE rolname='\\\$USER'" \
    "queries pg_roles before createuser"

assert_pattern_present "$PG_SCRIPT" "SELECT 1 FROM pg_database WHERE datname='\\\$USER'" \
    "queries pg_database before createdb (Mac path)"

assert_pattern_present "$PG_SCRIPT" 'createuser -s "\$USER"' \
    "creates role with -s (superuser)"

echo
echo "═══ Mac path — launch-wrapper integration ═══"

assert_pattern_present "$PG_SCRIPT" 'source.*lib/launch-wrapper\.sh' \
    "sources lib/launch-wrapper.sh"

assert_pattern_present "$PG_SCRIPT" 'launch_wrapper_install_extbrew' \
    "invokes launch_wrapper_install_extbrew (custom prefix path)"

assert_pattern_present "$PG_SCRIPT" '/opt/homebrew\|/usr/local' \
    "branches on canonical vs custom BREW_PREFIX"

echo
echo "═══ Linux path — PGDG APT repo + safe install ═══"

assert_pattern_present "$PG_SCRIPT" 'apt\.postgresql\.org/pub/repos/apt' \
    "uses PGDG APT repo (apt.postgresql.org)"

assert_pattern_present "$PG_SCRIPT" 'signed-by=\$KEYRING' \
    "uses modern signed-by keyring (not deprecated apt-key)"

assert_pattern_present "$PG_SCRIPT" '/etc/apt/keyrings/postgresql\.gpg' \
    "keyring lives under /etc/apt/keyrings/"

# `--no-install-recommends` would be parsed as a grep flag because it
# begins with `--`. Anchoring the first dash inside a char-class neutralises
# that without changing what we're matching.
assert_pattern_present "$PG_SCRIPT" '[-]-no-install-recommends' \
    "apt install uses --no-install-recommends (defends against PHP-recommends infection D43)"

assert_pattern_present "$PG_SCRIPT" 'sudo -u postgres createuser' \
    "Linux: createuser runs as postgres OS user (peer auth)"

assert_pattern_present "$PG_SCRIPT" 'sudo -u postgres createdb' \
    "Linux: createdb runs as postgres OS user (peer auth)"

echo
echo "═══ install.{mac,wsl}.sh wiring ═══"

assert_pattern_present "$MAC_INSTALL" 'INCLUDE_POSTGRES.*install-postgres\.sh' \
    "install.mac.sh wires INCLUDE_POSTGRES"

assert_pattern_present "$WSL_INSTALL" 'INCLUDE_POSTGRES.*install-postgres\.sh' \
    "install.wsl.sh wires INCLUDE_POSTGRES"

echo
echo "═══ lib/menu.sh — postgres extra + version prompt ═══"

assert_pattern_present "$MENU" '"postgres"' \
    "menu checklist contains 'postgres' item"

assert_pattern_present "$MENU" 'postgres\) export INCLUDE_POSTGRES=1' \
    "menu case map exports INCLUDE_POSTGRES"

assert_pattern_present "$MENU" 'POSTGRES_VERSION' \
    "menu handles POSTGRES_VERSION"

assert_pattern_present "$MENU" 'postgres version' \
    "menu has dedicated postgres version screen"

assert_pattern_present "$MENU" 'export POSTGRES_VERSION' \
    "menu exports POSTGRES_VERSION downstream"

echo
summary
