#!/usr/bin/env bash
# Real custom-owner regression coverage for the opt-in data purge lifecycle.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
source "$WS/tests/lib/assert.sh"

ROOT="$(mktemp -d -t mesh-purge-lifecycle.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin" FORM="$ROOT/formulas" HOME_FIX="$ROOT/home" BREW="$ROOT/brew"
mkdir -p "$BIN" "$FORM" "$HOME_FIX" "$BREW/var/db"

cat > "$BIN/brew" <<'SH'
#!/usr/bin/env bash
set -u
form="${FAKE_FORMULAS:?}"
case "${1:-}" in
  list) [[ "${2:-}" == "--formula" ]] && [[ -d "$form/${3:-}" ]] ;;
  unlink|services) exit 0 ;;
  uninstall)
    pkg="${!#}"
    rm -rf "$form/$pkg"
    ;;
  *) exit 0 ;;
esac
SH
cat > "$BIN/launchctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$BIN/sudo" <<'SH'
#!/usr/bin/env bash
shift 0
case "${1:-}" in
  rm)
    shift
    while [[ "${1:-}" == -* ]]; do shift; done
    case "${1:-}" in
      "${TEST_ROOT:?}"/*) exec /bin/rm -rf -- "$@" ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/brew" "$BIN/launchctl" "$BIN/sudo"

run_php_uninstall() {
    FAKE_FORMULAS="$FORM" BREW_BIN="$BIN/brew" BREW_PREFIX="$BREW" \
    PHP_VERSIONS=8.4 PATH="$BIN:$PATH" \
        bash -c '. "$1"; uninstall' _ "$WS/topics/languages/mac/php-stack.sh"
}

echo "PHP owner removes its declared version formula"
mkdir -p "$FORM/php@8.4" "$FORM/php"
: > "$FORM/php/.keep"
run_php_uninstall
ASSERT_MSG="PHP uninstall removes php@8.4" assert_false "[ -d '$FORM/php@8.4' ]"
assert_file_exists "$FORM/php/.keep" "normal PHP uninstall preserves an unversioned formula it does not own"
mkdir -p "$FORM/php@8.4"
MESH_PURGE_DATA=1 run_php_uninstall
ASSERT_MSG="confirmed PHP purge removes the unversioned PHP formula" assert_false "[ -d '$FORM/php' ]"

run_postgres_uninstall() {
    FAKE_FORMULAS="$FORM" BREW_BIN="$BIN/brew" BREW_PREFIX="$BREW" \
    POSTGRES_VERSION=17 HOME="$HOME_FIX" PATH="$BIN:$PATH" \
    MESH_WORKSTATION_DIR="$WS" \
        bash -c '. "$1"; uninstall' _ "$WS/topics/databases/postgresql.sh"
}

echo "PostgreSQL keeps data normally and removes it only with purge authority"
mkdir -p "$FORM/postgresql@17" "$BREW/var/postgresql@17"
: > "$BREW/var/postgresql@17/PG_VERSION"
run_postgres_uninstall
assert_file_exists "$BREW/var/postgresql@17/PG_VERSION" "normal PostgreSQL uninstall preserves cluster data"
mkdir -p "$FORM/postgresql@17"
MESH_PURGE_DATA=1 run_postgres_uninstall
ASSERT_MSG="confirmed PostgreSQL purge removes only its versioned data dir" assert_false "[ -e '$BREW/var/postgresql@17' ]"

run_redis_uninstall() {
    FAKE_FORMULAS="$FORM" BREW_BIN="$BIN/brew" BREW_PREFIX="$BREW" \
    HOME="$HOME_FIX" PATH="$BIN:$PATH" MESH_WORKSTATION_DIR="$WS" \
        bash -c '. "$1"; uninstall' _ "$WS/topics/databases/mac/redis.sh"
}

echo "Redis keeps data normally and removes it only with purge authority"
mkdir -p "$FORM/redis" "$BREW/var/db/redis"
: > "$BREW/var/db/redis/dump.rdb"
run_redis_uninstall
assert_file_exists "$BREW/var/db/redis/dump.rdb" "normal Redis uninstall preserves dump.rdb"
mkdir -p "$FORM/redis"
MESH_PURGE_DATA=1 run_redis_uninstall
ASSERT_MSG="confirmed Redis purge removes its canonical data dir" assert_false "[ -e '$BREW/var/db/redis' ]"

run_mysql_uninstall() {
    FAKE_FORMULAS="$FORM" BREW_BIN="$BIN/brew" BREW_PREFIX="$BREW" \
    MYSQL_ORACLE_PREFIX="$ROOT/mysql" HOME="$HOME_FIX" TEST_ROOT="$ROOT" \
    PATH="$BIN:$PATH" MESH_WORKSTATION_DIR="$WS" \
        bash -c '. "$1"; uninstall' _ "$WS/topics/databases/mac/mysql.sh"
}

echo "MySQL only purges the managed Oracle symlink target"
mkdir -p "$ROOT/mysql-9.7.0-macos15-arm64/bin" "$ROOT/mysql-9.7.0-macos15-arm64/data"
: > "$ROOT/mysql-9.7.0-macos15-arm64/bin/mysql"
: > "$ROOT/mysql-9.7.0-macos15-arm64/data/ibdata1"
ln -s "$ROOT/mysql-9.7.0-macos15-arm64" "$ROOT/mysql"
run_mysql_uninstall
assert_file_exists "$ROOT/mysql-9.7.0-macos15-arm64/data/ibdata1" "normal MySQL uninstall preserves Oracle data"
MESH_PURGE_DATA=1 run_mysql_uninstall
ASSERT_MSG="confirmed MySQL purge removes the managed symlink" assert_false "[ -e '$ROOT/mysql' ]"
ASSERT_MSG="confirmed MySQL purge removes the managed target only" assert_false "[ -e '$ROOT/mysql-9.7.0-macos15-arm64' ]"

summary
