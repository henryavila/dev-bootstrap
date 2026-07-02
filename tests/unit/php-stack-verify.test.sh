#!/usr/bin/env bash
# tests/unit/php-stack-verify.test.sh
#
# Regression for the mac PHP stack repair probe: PHP can exit 0 while emitting
# startup warnings for dangling extension ini files. verify() must fail that
# state so `mesh doctor --fix` repairs PHP before Valet asks Composer for a PHP.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
PHP_STACK="$WS/topics/languages/mac/php-stack.sh"
# shellcheck source=../lib/assert.sh
source "$WS/tests/lib/assert.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAKEBIN="$TMP/bin"
BREW_ROOT="$TMP/brew"
mkdir -p "$FAKEBIN" "$BREW_ROOT/opt/php@8.5/bin"

cat > "$FAKEBIN/brew" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "list" && "$2" == "--formula" && "$3" == "php@8.5" ]]; then
    exit 0
fi
exit 1
EOF

cat > "$FAKEBIN/composer" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && printf 'Composer 2.x\n'
exit 0
EOF

cat > "$FAKEBIN/python3" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$BREW_ROOT/opt/php@8.5/bin/php" <<'EOF'
#!/usr/bin/env bash
if [[ "${PHP_FAKE_STARTUP_WARNING:-0}" == "1" ]]; then
    printf 'Warning: PHP Startup: Unable to load dynamic library '\''redis.so'\'' (tried: /missing/redis.so) in Unknown on line 0\n'
fi
case "${1:-}" in
    --ini) printf 'Configuration File (php.ini) Path: /fake\n' ;;
    -v|--version) printf 'PHP 8.5.0\n' ;;
esac
exit 0
EOF
chmod +x "$FAKEBIN/brew" "$FAKEBIN/composer" "$FAKEBIN/python3" "$BREW_ROOT/opt/php@8.5/bin/php"

export PATH="$FAKEBIN:$PATH"
export BREW_BIN="$FAKEBIN/brew"
export BREW_PREFIX="$BREW_ROOT"
export PHP_VERSIONS="8.5"
export PHP_DEFAULT="8.5"

# shellcheck disable=SC1090
. "$PHP_STACK"

PHP_FAKE_STARTUP_WARNING=1 verify >"$TMP/warn.out" 2>"$TMP/warn.err"
assert_eq "$?" "1" "php-stack verify — fails when PHP emits startup library warnings despite rc 0"
assert_file_contains "$TMP/warn.err" "PHP Startup: Unable to load dynamic library" \
    "php-stack verify — surfaces the startup warning that forced repair"

PHP_FAKE_STARTUP_WARNING=0 verify >"$TMP/clean.out" 2>"$TMP/clean.err"
assert_eq "$?" "0" "php-stack verify — passes when PHP starts cleanly"

if declare -F repair >/dev/null 2>&1; then
    pass "php-stack repair — defines an explicit repair hook for the custom engine item"
else
    fail "php-stack repair — must define repair() so engine --repair can run install()"
fi
install() { printf 'install-called\n' >> "$TMP/repair.log"; }
repair >/dev/null 2>&1
assert_file_contains "$TMP/repair.log" "install-called" \
    "php-stack repair — delegates to install()"

summary
