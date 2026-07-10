#!/usr/bin/env bash
# tests/integration/php-stack-convergence.test.sh
#
# PHP convergence harness. Default mode uses frozen fixtures to reproduce the
# pre-fix failures without depending on the live production source remaining
# broken. Platform modes are the future green contracts for F1/F2.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
FIXTURES="$HERE/fixtures/php-stack"
MAC_STACK="$WS/topics/languages/mac/php-stack.sh"
WSL_STACK="$WS/topics/languages/wsl/php-stack.sh"
PECL_LIB="$WS/scripts/lib/pecl-install.sh"

# shellcheck source=../lib/assert.sh
# shellcheck disable=SC1091
source "$WS/tests/lib/assert.sh"

usage() {
    cat <<'USAGE'
usage: php-stack-convergence.test.sh [--platform mac|wsl] [--case name]

No arguments:
  Run frozen red-regression fixtures for the F0 contract harness.

--platform mac|wsl:
  Run the live source contract for the implementation phase.

--case name:
  Run one implementation contract case.
USAGE
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

helper_invocations_after_definition() {
    local file="$1"
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*pecl_install_for_mac[[:space:]]+/ {
            printf "%d:%s\n", FNR, $0
        }
    ' "$file"
}

helper_invocations_in_text() {
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*pecl_install_for_mac[[:space:]]+/ {
            printf "%d:%s\n", NR, $0
        }
    '
}

pecl_failure_branch() {
    sed -n '/if \[\[ "\$pecl_rc" -ne 0 \]\] || \[\[ ! -f "\$so_path" \]\]/,/^    fi/p' "$PECL_LIB"
}

run_fixture_mac_helper_gap() {
    local root sent refs
    root="$(mktemp -d -t php-stack-mac-gap.XXXXXX)"
    sent="$root/sentinels"
    mkdir -p "$sent"
    (
        # shellcheck disable=SC1091
        source "$FIXTURES/mac-pecl-helper-gap.sh"
        SENT_DIR="$sent" install
    )

    assert_file_exists "$sent/mac-ext-redis-seen" \
        "fixture sees the mac PECL extension line"
    assert_false "[ -f '$sent/mac-helper-called' ]"

    refs="$(helper_invocations_after_definition "$FIXTURES/mac-pecl-helper-gap.sh")"
    assert_eq "$refs" "" \
        "fixture freezes the mac helper-defined-but-not-invoked regression"
    rm -rf "$root"
}

run_fixture_wsl_pecl_success_on_failure() {
    local root log rc
    root="$(mktemp -d -t php-stack-wsl-pecl.XXXXXX)"
    log="$root/warn.log"
    (
        warn() { printf '%s\n' "$*" >> "$log"; }
        # shellcheck disable=SC1091
        source "$FIXTURES/wsl-pecl-success-on-failure.sh"
        pecl_install_for_version_linux "8.5" "redis"
    )
    rc=$?

    assert_eq "$rc" "0" \
        "fixture freezes WSL PECL failure returning success"
    assert_file_contains "$log" "pecl install redis failed" \
        "fixture records the PECL failure warning"
    rm -rf "$root"
}

run_fixture_orphan_ini_verify_gap() {
    local root fakebin rc
    root="$(mktemp -d -t php-stack-orphan-ini.XXXXXX)"
    fakebin="$root/bin"
    mkdir -p "$fakebin"
    cp "$FIXTURES/orphan-ini-php.sh" "$fakebin/php8.5"
    chmod +x "$fakebin/php8.5"
    cat > "$fakebin/composer" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/composer"

    (
        PATH="$fakebin:$PATH"
        PHP_ORPHAN_SENTINEL="$root/php-called"
        # shellcheck disable=SC1091
        source "$FIXTURES/wsl-weak-verify.sh"
        verify
    )
    rc=$?

    assert_eq "$rc" "0" \
        "fixture freezes WSL verify passing despite an active orphan INI warning"
    assert_false "[ -f '$root/php-called' ]"
    rm -rf "$root"
}

run_fixture_clean_php_contract() {
    local root brew phpbin rc out
    root="$(mktemp -d -t php-stack-clean-contract.XXXXXX)"
    brew="$root/brew"
    phpbin="$brew/opt/php@8.5/bin"
    mkdir -p "$phpbin"
    cp "$FIXTURES/orphan-ini-php.sh" "$phpbin/php"
    chmod +x "$phpbin/php"

    # shellcheck disable=SC1091
    source "$MAC_STACK"
    out="$(BREW_PREFIX="$brew" _php_cli_starts_clean "8.5" 2>&1)"
    rc=$?

    [[ "$rc" -ne 0 ]] && pass "clean PHP contract fails when --ini emits PHP Startup" \
        || fail "clean PHP contract accepted an orphan INI startup warning"
    assert_contains "$out" "PHP Startup" \
        "clean PHP contract surfaces the startup warning"
    rm -rf "$root"
}

run_red_fixtures() {
    run_fixture_mac_helper_gap
    run_fixture_wsl_pecl_success_on_failure
    run_fixture_orphan_ini_verify_gap
    run_fixture_clean_php_contract
}

run_platform_mac_pecl_loop() {
    local install_body refs

    install_body="$(function_body install "$MAC_STACK")"
    refs="$(printf '%s\n' "$install_body" | helper_invocations_in_text)"
    if [[ -n "$refs" ]]; then
        pass "mac production source invokes pecl_install_for_mac"
    else
        fail "mac production source defines pecl_install_for_mac but never invokes it"
    fi

    assert_contains "$install_body" 'for line in "${PECL_LINES[@]}"' \
        "mac PECL loop iterates configured extension lines"
    assert_contains "$install_body" 'for ver in $PHP_VERSIONS' \
        "mac PECL loop iterates configured PHP versions"
}

install_fake_mac_verify_env() {
    local root="$1" brew="$2" fakebin="$3" ver phpbin
    mkdir -p "$fakebin"
    cat > "$fakebin/brew" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" && "${2:-}" == "--formula" ]]; then
    exit 0
fi
exit 1
SH
    cat > "$fakebin/composer" <<'SH'
#!/usr/bin/env bash
printf 'Composer version fixture\n'
SH
    cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/brew" "$fakebin/composer" "$fakebin/python3"

    for ver in 8.4 8.5; do
        phpbin="$brew/opt/php@${ver}/bin"
        mkdir -p "$phpbin"
        cat > "$phpbin/php" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
    --ini)
        if [[ "\${PHP_FAKE_STARTUP_DIRTY:-}" == "$ver" ]]; then
            printf 'PHP Startup: Unable to load dynamic library redis.so\n' >&2
        fi
        exit 0
        ;;
    -m)
        printf 'Core\n'
        for ext in igbinary imagick mongodb pcov redis; do
            if [[ "\${PHP_FAKE_MISSING_VER:-}" == "$ver" && "\${PHP_FAKE_MISSING_EXT:-}" == "\$ext" ]]; then
                continue
            fi
            printf '%s\n' "\$ext"
        done
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
SH
        chmod +x "$phpbin/php"
    done
    : > "$root/env-ready"
}

run_platform_mac_verify() {
    local verify_body root brew fakebin rc out

    verify_body="$(function_body verify "$MAC_STACK")"
    assert_contains "$verify_body" "_php_cli_starts_clean" \
        "mac verify requires clean PHP startup for every declared version"
    assert_contains "$verify_body" "_php_pecl_extensions_for_stack" \
        "mac verify reads the declared PECL baseline"
    assert_contains "$verify_body" "_php_module_loaded_for_version" \
        "mac verify checks PECL modules per PHP version"
    assert_contains "$verify_body" "composer --version" \
        "mac verify checks Composer execution"

    root="$(mktemp -d -t php-stack-mac-verify.XXXXXX)"
    brew="$root/brew"
    fakebin="$root/bin"
    install_fake_mac_verify_env "$root" "$brew" "$fakebin"
    out="$(
        env \
            PATH="$fakebin:$PATH" \
            BREW_PREFIX="$brew" \
            BREW_BIN="$fakebin/brew" \
            PHP_VERSIONS="8.4 8.5" \
            bash -c 'source "$1"; verify' _ "$MAC_STACK" 2>&1
    )"
    rc=$?
    assert_eq "$rc" "0" \
        "mac verify passes when every PHP version loads every declared PECL module"

    out="$(
        env \
            PATH="$fakebin:$PATH" \
            BREW_PREFIX="$brew" \
            BREW_BIN="$fakebin/brew" \
            PHP_VERSIONS="8.4 8.5" \
            PHP_FAKE_MISSING_VER="8.5" \
            PHP_FAKE_MISSING_EXT="redis" \
            bash -c 'source "$1"; verify' _ "$MAC_STACK" 2>&1
    )"
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
        pass "mac verify fails when a declared PECL module is absent"
    else
        fail "mac verify accepted a missing declared PECL module"
    fi
    assert_contains "$out" "php@8.5: required PECL extension redis is not loaded" \
        "mac verify identifies the missing PECL module"
    rm -rf "$root"
}

run_platform_mac() {
    local case_filter="${1:-all}"

    case "$case_filter" in
        all)
            run_platform_mac_pecl_loop
            run_platform_mac_verify
            ;;
        pecl-loop)
            run_platform_mac_pecl_loop
            return
            ;;
        verify)
            run_platform_mac_verify
            return
            ;;
        *)
            fail "unknown mac --case value: $case_filter"
            return
            ;;
    esac
}

run_platform_wsl() {
    local branch verify_body

    branch="$(pecl_failure_branch)"
    assert_not_contains "$branch" "return 0" \
        "WSL PECL build failure is not reported as success"

    verify_body="$(function_body verify "$WSL_STACK")"
    if [[ "$verify_body" == *"PHP Startup"* || "$verify_body" == *"--ini"* || "$verify_body" == *"_php_cli_starts_clean"* ]]; then
        pass "WSL verify checks clean PHP startup"
    else
        fail "WSL verify does not check PHP startup warnings or orphan INIs"
    fi
}

case "${1:-}" in
    "")
        run_red_fixtures
        ;;
    --platform)
        case "${2:-}" in
            mac) run_platform_mac "${4:-all}" ;;
            wsl) run_platform_wsl ;;
            *)
                usage >&2
                fail "unknown --platform value: ${2:-}"
                ;;
        esac
        ;;
    --platform=mac)
        run_platform_mac "${3:-all}"
        ;;
    --platform=wsl)
        run_platform_wsl
        ;;
    -h|--help)
        usage
        ;;
    *)
        usage >&2
        fail "unknown argument: $1"
        ;;
esac

summary
