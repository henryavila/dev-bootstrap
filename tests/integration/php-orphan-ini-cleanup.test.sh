#!/usr/bin/env bash
# tests/integration/php-orphan-ini-cleanup.test.sh
#
# Contract tests for the macOS orphan INI cleanup topic. These use a fake
# Homebrew prefix so the test never reads or mutates the developer's PHP config.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
SCRIPT="$WS/topics/languages/mac/orphan-ini-cleanup.sh"
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
usage: php-orphan-ini-cleanup.test.sh --platform mac
USAGE
}

write_ini() {
    local path="$1" value="$2"
    mkdir -p "$(dirname "$path")"
    printf 'extension=%s\n' "$value" > "$path"
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
    local root brew state ver conf cellar_ext fallback_ext canonical_ext
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

    local ext
    for ext in igbinary imagick mongodb redis; do
        write_ini "$conf/ext-${ext}.ini" "${ext}.so"
    done
    write_ini "$conf/ext-pcov.ini" "pcov.so"
    : > "$fallback_ext/pcov.so"
    write_ini "$conf/ext-xdebug.ini" "xdebug.so"
    write_ini "$conf/99-bare-imagick.ini" "imagick.so"
    write_ini "$conf/99-absolute-missing.ini" "$root/missing/legacy.so"

    mesh_state_dir() { printf '%s\n' "$state"; }
    warn() { printf 'warn: %s\n' "$*" >&2; }
    followup() { :; }

    # shellcheck disable=SC1090
    source "$SCRIPT"
    BREW_PREFIX="$brew" install

    for ext in igbinary imagick mongodb redis; do
        assert_false "[ -f '$conf/ext-${ext}.ini' ]"
        assert_file_exists "$state/orphan-ini-quarantine/ext-${ext}.ini" \
            "mac cleanup quarantines stale ext-${ext}.ini"
    done
    assert_file_exists "$conf/ext-pcov.ini" \
        "mac cleanup keeps declared extension ini when a candidate .so exists"
    assert_file_exists "$conf/ext-xdebug.ini" \
        "mac cleanup keeps ext ini outside mesh-owned PECL list"
    assert_file_exists "$conf/99-bare-imagick.ini" \
        "mac cleanup keeps bare module names in legacy 99 ini"
    assert_false "[ -f '$conf/99-absolute-missing.ini' ]"
    assert_file_exists "$state/orphan-ini-quarantine/99-absolute-missing.ini" \
        "mac cleanup preserves legacy absolute-path orphan quarantine"
}

case "${1:-}" in
    --platform)
        case "${2:-}" in
            mac) run_platform_mac ;;
            *)
                usage >&2
                fail "unknown --platform value: ${2:-}"
                ;;
        esac
        ;;
    --platform=mac)
        run_platform_mac
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
