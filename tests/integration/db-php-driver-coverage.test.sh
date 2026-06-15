#!/usr/bin/env bash
# tests/integration/db-php-driver-coverage.test.sh
#
# Contract: every relational/cache database the `databases` topic offers as a
# bundle MUST have its PHP client driver installed by the bootstrap. Otherwise
# a user runs `mesh install`, picks PostgreSQL, gets the server + a role + a db,
# is even told to put `DB_CONNECTION=pgsql` in Laravel's .env (the postgres
# installer prints exactly that) — and then PHP cannot connect because the
# `pdo_pgsql` extension was never installed.
#
# How drivers reach PHP today (two mechanisms):
#   1. languages/data/php-extensions-apt.txt — the WSL/apt baseline. The
#      installer prepends `php8.X-` per version, so a line `pgsql` becomes
#      `php8.4-pgsql` (which provides BOTH `pgsql` and `pdo_pgsql`).
#   2. languages/data/php-extensions-pecl.txt — PECL-built extensions (redis,
#      mongodb, …), built once per PHP version.
#   3. A DB item may install its own driver (mssql-driver builds sqlsrv +
#      pdo_sqlsrv itself; covered by its own php-extensions-mssql.txt).
#
# This test guards the mapping bundle → driver so a future DB added to the
# manifest without a PHP driver fails loudly here instead of silently in prod.
#
# This is a STATIC contract test (greps the data files) — no PHP/apt needed,
# so it runs on every platform.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

APT_EXTS="$ROOT/topics/languages/data/php-extensions-apt.txt"
PECL_EXTS="$ROOT/topics/languages/data/php-extensions-pecl.txt"
MSSQL_EXTS="$ROOT/topics/languages/data/php-extensions-mssql.txt"

assert_file_exists "$APT_EXTS"
assert_file_exists "$PECL_EXTS"

# Each driver is a bare token on its own line. In the apt file that's the
# whole line (`^token$`); in the PECL file a line may carry build deps after a
# colon (`^token` then `:` or end-of-line). `^token([[:space:]]*$|:)` matches
# both, while NOT matching a longer name that merely starts with the token.

# ── MySQL → php-*-mysql (pdo_mysql + mysqli), apt baseline ──────────────────
assert_pattern_present "$APT_EXTS" '^mysql[[:space:]]*$' \
    "MySQL bundle: 'mysql' present in apt baseline (provides pdo_mysql)"

# ── SQLite → php-*-sqlite3 (pdo_sqlite), apt baseline ───────────────────────
assert_pattern_present "$APT_EXTS" '^sqlite3[[:space:]]*$' \
    "SQLite: 'sqlite3' present in apt baseline (provides pdo_sqlite)"

# ── PostgreSQL → php-*-pgsql (pgsql + pdo_pgsql), apt baseline ──────────────
# THE FIX: the postgresql bundle installs the server but nothing installed the
# PHP driver. `php8.X-pgsql` provides both `pgsql` and `pdo_pgsql`.
assert_pattern_present "$APT_EXTS" '^pgsql[[:space:]]*$' \
    "PostgreSQL bundle: 'pgsql' present in apt baseline (provides pdo_pgsql)"

# ── Redis → phpredis, PECL baseline ─────────────────────────────────────────
assert_pattern_present "$PECL_EXTS" '^redis([[:space:]]*$|:)' \
    "Redis bundle: 'redis' present in PECL baseline (phpredis)"

# ── MS SQL → sqlsrv + pdo_sqlsrv, installed by the mssql-driver item itself ─
# Not in the global baseline by design (corporate opt-in, WSL only); the item
# builds it from its own data file.
assert_file_exists "$MSSQL_EXTS"
assert_pattern_present "$MSSQL_EXTS" '^sqlsrv$' \
    "MS SQL: 'sqlsrv' declared in mssql-driver's own extension list"
assert_pattern_present "$MSSQL_EXTS" '^pdo_sqlsrv$' \
    "MS SQL: 'pdo_sqlsrv' declared in mssql-driver's own extension list"

summary
