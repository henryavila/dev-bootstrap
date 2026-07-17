#!/usr/bin/env bash
# Real custom-owner regression coverage for the opt-in data purge lifecycle.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
source "$WS/tests/lib/assert.sh"

ROOT="$(mktemp -d -t mesh-purge-lifecycle.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin" FORM="$ROOT/formulas" HOME_FIX="$ROOT/home" BREW="$ROOT/brew" DAEMONS="$ROOT/LaunchDaemons" SUDO_LOG="$ROOT/sudo.log"
mkdir -p "$BIN" "$FORM" "$HOME_FIX/Library/LaunchAgents" "$BREW/var/db" "$DAEMONS"

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
printf '%s\n' "$*" >> "${SUDO_LOG:?}"
case "${1:-}" in
  launchctl)
    exit 0
    ;;
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
    MESH_PHP_LAUNCHDAEMON_DIR="$DAEMONS" PHP_VERSIONS=8.4 SUDO_LOG="$SUDO_LOG" \
    TEST_ROOT="$ROOT" PATH="$BIN:$PATH" \
        bash -c '. "$1"; uninstall' _ "$WS/topics/languages/mac/php-stack.sh"
}

echo "PHP owner removes its declared version formula"
mkdir -p "$FORM/php@8.4" "$FORM/php"
: > "$FORM/php/.keep"
mkdir -p "$BREW/etc/php"
: > "$BREW/etc/php/php.ini"
: > "$DAEMONS/homebrew.mxcl.php.plist"
run_php_uninstall
ASSERT_MSG="PHP uninstall removes php@8.4" assert_false "[ -d '$FORM/php@8.4' ]"
assert_file_exists "$FORM/php/.keep" "normal PHP uninstall preserves an unversioned formula it does not own"
assert_file_exists "$BREW/etc/php/php.ini" "normal PHP uninstall preserves PHP configuration"
assert_file_exists "$DAEMONS/homebrew.mxcl.php.plist" "normal PHP uninstall preserves the bare PHP daemon"
mkdir -p "$FORM/php@8.4"
MESH_PURGE_DATA=1 run_php_uninstall
ASSERT_MSG="confirmed PHP purge removes the unversioned PHP formula" assert_false "[ -d '$FORM/php' ]"
ASSERT_MSG="confirmed PHP purge removes canonical PHP configuration" assert_false "[ -e '$BREW/etc/php' ]"
ASSERT_MSG="confirmed PHP purge removes the stale system PHP daemon" assert_false "[ -e '$DAEMONS/homebrew.mxcl.php.plist' ]"
assert_file_contains "$SUDO_LOG" "launchctl bootout system/homebrew.mxcl.php" "confirmed PHP purge boots out the stale daemon before deletion"

echo "INI cleanup owner has no persistent artifact after uninstall"
ASSERT_MSG="INI cleanup owner declares an honest no-op uninstall" assert_true "bash -c '. \"$WS/topics/languages/mac/orphan-ini-cleanup.sh\"; uninstall'"

run_postgres_uninstall() {
    FAKE_FORMULAS="$FORM" BREW_BIN="$BIN/brew" BREW_PREFIX="$BREW" \
    POSTGRES_VERSION=17 HOME="$HOME_FIX" PATH="$BIN:$PATH" \
    MESH_WORKSTATION_DIR="$WS" \
        bash -c '. "$1"; uninstall' _ "$WS/topics/databases/postgresql.sh"
}

echo "PostgreSQL keeps data normally and removes it only with purge authority"
mkdir -p "$FORM/postgresql@17" "$BREW/var/postgresql@17"
: > "$BREW/var/postgresql@17/PG_VERSION"
: > "$HOME_FIX/Library/LaunchAgents/homebrew.mxcl.postgresql@17.plist.bak"
run_postgres_uninstall
assert_file_exists "$BREW/var/postgresql@17/PG_VERSION" "normal PostgreSQL uninstall preserves cluster data"
assert_file_exists "$HOME_FIX/Library/LaunchAgents/homebrew.mxcl.postgresql@17.plist.bak" "normal PostgreSQL uninstall preserves service backup"
mkdir -p "$FORM/postgresql@17"
MESH_PURGE_DATA=1 run_postgres_uninstall
ASSERT_MSG="confirmed PostgreSQL purge removes only its versioned data dir" assert_false "[ -e '$BREW/var/postgresql@17' ]"
ASSERT_MSG="confirmed PostgreSQL purge removes its stale service backup" assert_false "[ -e '$HOME_FIX/Library/LaunchAgents/homebrew.mxcl.postgresql@17.plist.bak' ]"

run_redis_uninstall() {
    FAKE_FORMULAS="$FORM" BREW_BIN="$BIN/brew" BREW_PREFIX="$BREW" \
    HOME="$HOME_FIX" PATH="$BIN:$PATH" MESH_WORKSTATION_DIR="$WS" \
        bash -c '. "$1"; uninstall' _ "$WS/topics/databases/mac/redis.sh"
}

echo "Redis keeps data normally and removes it only with purge authority"
mkdir -p "$FORM/redis" "$BREW/var/db/redis"
: > "$BREW/var/db/redis/dump.rdb"
: > "$BREW/etc/redis.conf"
: > "$BREW/etc/redis-sentinel.conf"
: > "$HOME_FIX/Library/LaunchAgents/homebrew.mxcl.redis.plist.bak"
run_redis_uninstall
assert_file_exists "$BREW/var/db/redis/dump.rdb" "normal Redis uninstall preserves dump.rdb"
assert_file_exists "$BREW/etc/redis.conf" "normal Redis uninstall preserves configuration"
assert_file_exists "$HOME_FIX/Library/LaunchAgents/homebrew.mxcl.redis.plist.bak" "normal Redis uninstall preserves service backup"
mkdir -p "$FORM/redis"
MESH_PURGE_DATA=1 run_redis_uninstall
ASSERT_MSG="confirmed Redis purge removes its canonical data dir" assert_false "[ -e '$BREW/var/db/redis' ]"
ASSERT_MSG="confirmed Redis purge removes canonical configuration" assert_false "[ -e '$BREW/etc/redis.conf' ]"
ASSERT_MSG="confirmed Redis purge removes sentinel configuration" assert_false "[ -e '$BREW/etc/redis-sentinel.conf' ]"
ASSERT_MSG="confirmed Redis purge removes its stale service backup" assert_false "[ -e '$HOME_FIX/Library/LaunchAgents/homebrew.mxcl.redis.plist.bak' ]"

run_mysql_uninstall() {
    FAKE_FORMULAS="$FORM" BREW_BIN="$BIN/brew" BREW_PREFIX="$BREW" \
    MYSQL_ORACLE_PREFIX="$ROOT/mysql" HOME="$HOME_FIX" TEST_ROOT="$ROOT" \
    SUDO_LOG="$SUDO_LOG" PATH="$BIN:$PATH" MESH_WORKSTATION_DIR="$WS" \
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
MESH_PURGE_DATA=1 run_mysql_uninstall
ASSERT_MSG="confirmed MySQL purge is idempotent after its managed tree is gone" assert_true "MESH_PURGE_DATA=1 run_mysql_uninstall"

run_valet_uninstall() {
    HOME="$HOME_FIX" PATH="$BIN:$PATH" SUDO_LOG="$SUDO_LOG" \
    MESH_WORKSTATION_DIR="$WS" \
        bash -c '. "$1"; uninstall' _ "$WS/topics/web/mac/valet.sh"
}

echo "Valet removes Composer entry normally and user config only with purge authority"
mkdir -p "$HOME_FIX/.composer/vendor/bin" "$HOME_FIX/.composer/vendor/laravel/valet" "$HOME_FIX/.config/valet"
: > "$HOME_FIX/.composer/vendor/bin/valet"
: > "$HOME_FIX/.composer/vendor/laravel/valet/valet"
: > "$HOME_FIX/.config/valet/config.json"
chmod +x "$HOME_FIX/.composer/vendor/bin/valet"
run_valet_uninstall
ASSERT_MSG="normal Valet uninstall removes the Composer bin shim" assert_false "[ -e '$HOME_FIX/.composer/vendor/bin/valet' ]"
ASSERT_MSG="normal Valet uninstall removes the Composer package tree" assert_false "[ -e '$HOME_FIX/.composer/vendor/laravel/valet' ]"
assert_file_exists "$HOME_FIX/.config/valet/config.json" "normal Valet uninstall preserves user Valet config"

mkdir -p "$HOME_FIX/.composer/vendor/bin" "$HOME_FIX/.composer/vendor/laravel/valet" "$HOME_FIX/.config/valet"
: > "$HOME_FIX/.composer/vendor/bin/valet"
: > "$HOME_FIX/.composer/vendor/laravel/valet/valet"
: > "$HOME_FIX/.config/valet/config.json"
chmod +x "$HOME_FIX/.composer/vendor/bin/valet"
MESH_PURGE_DATA=1 run_valet_uninstall
ASSERT_MSG="confirmed Valet purge removes user Valet config" assert_false "[ -e '$HOME_FIX/.config/valet' ]"
assert_file_contains "$SUDO_LOG" "launchctl bootout system/homebrew.mxcl.php" "Valet uninstall attempts to unload PHP LaunchDaemon"
assert_file_contains "$SUDO_LOG" "launchctl bootout system/homebrew.mxcl.nginx" "Valet uninstall attempts to unload nginx LaunchDaemon"
assert_file_contains "$SUDO_LOG" "launchctl bootout system/homebrew.mxcl.dnsmasq" "Valet uninstall attempts to unload dnsmasq LaunchDaemon"

summary
