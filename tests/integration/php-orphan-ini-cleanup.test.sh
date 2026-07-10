#!/usr/bin/env bash
# tests/integration/php-orphan-ini-cleanup.test.sh
#
# Contract tests for orphan INI cleanup. These use fake PHP config roots so the
# test never reads or mutates the developer's PHP config.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
MAC_SCRIPT="$WS/topics/languages/mac/orphan-ini-cleanup.sh"
WSL_STACK="$WS/topics/languages/wsl/php-stack.sh"
ROOT_TO_CLEAN=""

# shellcheck source=../lib/assert.sh
# shellcheck disable=SC1091
source "$WS/tests/lib/assert.sh"

cleanup() {
    [[ -n "$ROOT_TO_CLEAN" ]] && rm -rf "$ROOT_TO_CLEAN"
}
trap cleanup EXIT

usage() {
    cat <<'USAGE'
usage: php-orphan-ini-cleanup.test.sh --platform mac|wsl
USAGE
}

write_ini() {
    local path="$1" value="$2"
    mkdir -p "$(dirname "$path")"
    printf 'extension=%s\n' "$value" > "$path"
}

function_body() {
    local name="$1" file="$2"
    awk -v name="$name" '
        $0 ~ "^" name "\\(\\)[[:space:]]*\\{" { capture=1; depth=0 }
        capture {
            print
            line=$0
            opens=gsub(/\{/, "{", line)
            line=$0
            closes=gsub(/\}/, "}", line)
            depth += opens - closes
            if (depth <= 0) exit
        }
    ' "$file"
}

install_fake_php_config() {
    local brew="$1" ver="$2" ext_dir="$3"
    local bin="$brew/opt/php@${ver}/bin"
    mkdir -p "$bin"
    cat > "$bin/php-config" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == "--extension-dir" ]]; then
    printf '%s\n' "$ext_dir"
    exit 0
fi
exit 1
SH
    chmod +x "$bin/php-config"
}

run_platform_mac() {
    local root brew state ver conf cellar_ext fallback_ext canonical_ext other_ver other_conf other_cellar_ext
    root="$(mktemp -d -t php-orphan-ini-cleanup.XXXXXX)"
    ROOT_TO_CLEAN="$root"

    brew="$root/brew"
    state="$root/state"
    ver="8.5"
    conf="$brew/etc/php/$ver/conf.d"
    cellar_ext="$brew/Cellar/php@$ver/$ver.0/pecl/20240924"
    fallback_ext="$brew/lib/php/pecl/20240924"
    canonical_ext="$brew/Cellar/php@$ver/$ver.0/lib/php/20240924"
    mkdir -p "$conf" "$cellar_ext" "$fallback_ext" "$canonical_ext"
    install_fake_php_config "$brew" "$ver" "$cellar_ext"
    other_ver="8.4"
    other_conf="$brew/etc/php/$other_ver/conf.d"
    other_cellar_ext="$brew/Cellar/php@$other_ver/$other_ver.0/pecl/20230831"
    mkdir -p "$other_conf" "$other_cellar_ext"
    install_fake_php_config "$brew" "$other_ver" "$other_cellar_ext"

    local ext
    for ext in igbinary imagick mongodb redis; do
        write_ini "$conf/ext-${ext}.ini" "${ext}.so"
    done
    write_ini "$conf/ext-pcov.ini" "pcov.so"
    : > "$fallback_ext/pcov.so"
    write_ini "$conf/ext-xdebug.ini" "xdebug.so"
    write_ini "$conf/99-bare-imagick.ini" "imagick.so"
    write_ini "$conf/99-absolute-missing.ini" "$root/missing/legacy.so"
    write_ini "$other_conf/ext-redis.ini" "redis.so"

    mesh_state_dir() { printf '%s\n' "$state"; }
    warn() { printf 'warn: %s\n' "$*" >&2; }
    followup() { :; }

    # shellcheck disable=SC1090
    source "$MAC_SCRIPT"
    BREW_PREFIX="$brew" install

    for ext in igbinary imagick mongodb redis; do
        assert_false "[ -f '$conf/ext-${ext}.ini' ]"
        assert_file_exists "$state/orphan-ini-quarantine/etc__php__${ver}__conf.d__ext-${ext}.ini" \
            "mac cleanup quarantines stale ext-${ext}.ini"
    done
    assert_file_exists "$conf/ext-pcov.ini" \
        "mac cleanup keeps declared extension ini when a candidate .so exists"
    assert_file_exists "$conf/ext-xdebug.ini" \
        "mac cleanup keeps ext ini outside mesh-owned PECL list"
    assert_file_exists "$conf/99-bare-imagick.ini" \
        "mac cleanup keeps bare module names in legacy 99 ini"
    assert_false "[ -f '$conf/99-absolute-missing.ini' ]"
    assert_file_exists "$state/orphan-ini-quarantine/etc__php__${ver}__conf.d__99-absolute-missing.ini" \
        "mac cleanup preserves legacy absolute-path orphan quarantine"
    assert_file_exists "$state/orphan-ini-quarantine/etc__php__${other_ver}__conf.d__ext-redis.ini" \
        "mac cleanup keeps version-specific quarantine entries distinct"
}

install_fake_wsl_php_config() {
    local fakebin="$1" ver="$2" ext_dir="$3"
    cat > "$fakebin/php-config${ver}" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == "--extension-dir" ]]; then
    printf '%s\n' "$ext_dir"
    exit 0
fi
if [[ "\${1:-}" == "--phpapi" ]]; then
    printf '%s\n' "$(basename "$ext_dir")"
    exit 0
fi
exit 1
SH
    chmod +x "$fakebin/php-config${ver}"
}

run_platform_wsl() {
    local root state fakebin etc ext_root ext85 ext84 ver ini_root install_body calls
    root="$(mktemp -d -t php-orphan-ini-cleanup-wsl.XXXXXX)"
    ROOT_TO_CLEAN="$root"
    state="$root/state"
    fakebin="$root/bin"
    etc="$root/etc/php"
    ext_root="$root/usr/lib/php"
    ext85="$ext_root/20250901"
    ext84="$ext_root/20240831"
    mkdir -p "$fakebin" "$etc" "$ext85" "$ext84"

    cat > "$fakebin/sudo" <<'SH'
#!/usr/bin/env bash
exec "$@"
SH
    chmod +x "$fakebin/sudo"
    install_fake_wsl_php_config "$fakebin" "8.5" "$ext85"
    install_fake_wsl_php_config "$fakebin" "8.4" "$ext84"

    for ver in 8.5 8.4; do
        ini_root="$etc/$ver"
        mkdir -p "$ini_root/mods-available" "$ini_root/cli/conf.d" "$ini_root/fpm/conf.d"
        write_ini "$ini_root/mods-available/redis.ini" "redis.so"
        ln -s "../../mods-available/redis.ini" "$ini_root/cli/conf.d/20-redis.ini"
    done

    write_ini "$etc/8.5/mods-available/pcov.ini" "pcov.so"
    ln -s "../../mods-available/pcov.ini" "$etc/8.5/cli/conf.d/20-pcov.ini"
    : > "$ext85/pcov.so"

    write_ini "$etc/8.5/mods-available/mbstring.ini" "mbstring.so"
    ln -s "../../mods-available/mbstring.ini" "$etc/8.5/cli/conf.d/20-mbstring.ini"

    mesh_state_dir() { printf '%s\n' "$state"; }
    warn() { printf 'warn: %s\n' "$*" >&2; }
    followup() { :; }

    # shellcheck disable=SC1090
    source "$WSL_STACK"

    install_body="$(function_body install "$WSL_STACK")"
    calls="$(printf '%s\n' "$install_body" | awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*_quarantine_stale_wsl_pecl_inis([[:space:]]|$|\|\|)/ { print }
    ')"
    [[ -n "$calls" ]] && pass "WSL install invokes stale PECL INI quarantine" \
        || fail "WSL install does not invoke stale PECL INI quarantine"

    PATH="$fakebin:$PATH" \
    PHP_CLI_BIN_DIR="$fakebin" \
    PHP_ETC_ROOT="$etc" \
    MESH_STATE_DIR="$state" \
    PHP_VERSIONS="8.4 8.5" \
    _quarantine_stale_wsl_pecl_inis

    for ver in 8.5 8.4; do
        assert_false "[ -e '$etc/$ver/cli/conf.d/20-redis.ini' ]"
        assert_false "[ -e '$etc/$ver/mods-available/redis.ini' ]"
        ASSERT_MSG="WSL cleanup quarantines active redis symlink for PHP $ver" \
            assert_true "[ -L '$state/orphan-ini-quarantine/${ver}__cli__conf.d__20-redis.ini' ]"
        assert_file_exists "$state/orphan-ini-quarantine/${ver}__mods-available__redis.ini" \
            "WSL cleanup quarantines redis mods-available ini for PHP $ver"
    done
    assert_file_exists "$etc/8.5/cli/conf.d/20-pcov.ini" \
        "WSL cleanup keeps PECL ini when the version's .so exists"
    assert_file_exists "$etc/8.5/mods-available/pcov.ini" \
        "WSL cleanup keeps PECL mods-available ini when the version's .so exists"
    assert_file_exists "$etc/8.5/cli/conf.d/20-mbstring.ini" \
        "WSL cleanup keeps apt-owned module symlink outside mesh PECL list"
    assert_file_exists "$etc/8.5/mods-available/mbstring.ini" \
        "WSL cleanup keeps apt-owned module ini outside mesh PECL list"
}

case "${1:-}" in
    --platform)
        case "${2:-}" in
            mac) run_platform_mac ;;
            wsl) run_platform_wsl ;;
            *)
                usage >&2
                fail "unknown --platform value: ${2:-}"
                ;;
        esac
        ;;
    --platform=mac)
        run_platform_mac
        ;;
    --platform=wsl)
        run_platform_wsl
        ;;
    -h|--help)
        usage
        ;;
    *)
        usage >&2
        fail "unknown argument: ${1:-}"
        ;;
esac

summary
