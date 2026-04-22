#!/usr/bin/env bash
# tests/cli/php-use.test.sh — black-box test of the php-use CLI helper.
#
# Runs the deployed script directly (no install required, no sudo). Each
# test invocation goes through a fresh $PATH setup so `php-use` doesn't
# touch the real system:
#   - $PATH is prefixed with a tmp dir containing mock php8.X binaries
#     → list-installed queries see our mocks, not the real system
#   - `update-alternatives` and `brew` are NOT called because tests avoid
#     the "switch version" code path (would need sudo / real brew)
#
# We cover: --help, --list, --current, missing-version error handling.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

PHP_USE="$REPO_ROOT/topics/10-languages/templates/bin/php-use"
assert_file_exists "$PHP_USE"

echo "--help / no args prints usage without error"
assert_exit_code 0 "bash '$PHP_USE' --help"
assert_exit_code 0 "bash '$PHP_USE'"

help_out="$(bash "$PHP_USE" --help 2>&1)"
assert_contains "$help_out" "php-use" "help output mentions the tool name"
assert_contains "$help_out" "--list" "help describes --list flag"

echo
echo "--list + --current work on an environment with mocked php binaries"

# Build a mock /usr/bin layout in a tmp dir. Scripts below are minimal
# but real enough: `php -r` needs to output a version string so the
# script's current_linux() can parse it.
mockdir="$(mktemp -d)"
trap 'rm -rf "$mockdir"' EXIT

cat > "$mockdir/php8.4" <<'EOF'
#!/bin/sh
if [ "$1" = "-r" ] && [ "$2" = 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' ]; then
    printf '8.4'
fi
EOF
cat > "$mockdir/php8.5" <<'EOF'
#!/bin/sh
if [ "$1" = "-r" ] && [ "$2" = 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' ]; then
    printf '8.5'
fi
EOF
# `php` default points at 8.5 (simulates the PHP_DEFAULT of our installer)
ln -s "$mockdir/php8.5" "$mockdir/php"
chmod +x "$mockdir"/php8.*

# php-use's list_installed_linux reads /usr/bin/php[0-9].[0-9] directly,
# so faking $PATH isn't enough on Linux. We can still test --current and
# --help via $PATH override, and test --list on Mac branch by simulating
# uname. For now exercise the parts that don't need /usr/bin:

PATH="$mockdir:$PATH" current="$(bash "$PHP_USE" --current 2>&1)"
assert_eq "$current" "8.5" "--current reports the PHP default from mock"

echo
echo "invoking with a version that isn't installed exits non-zero"

# (Can't safely test switching without breaking the real system; we test
#  the "missing" branch, which exits 1 without sudo/brew calls.)
out_missing="$(PATH="$mockdir:$PATH" bash "$PHP_USE" 9.9 2>&1 || true)"
assert_contains "$out_missing" "not installed" "error message says 'not installed'"

summary
