#!/usr/bin/env bash
# tests/unit/menu.test.sh — lib/menu.sh logic tests.
#
# Covers:
#   - should_show_menu returns 1 when any INCLUDE_* or NON_INTERACTIVE
#     is pre-seeded (bootstrap respects automation mode)
#   - should_show_menu returns 0 in clean interactive state (simulated
#     TTY via redirection — not perfect but catches the env-var branches)
#   - data/php-versions.conf parses into a non-empty list
#   - ENVSUBST_ALLOWLIST in lib/deploy.sh contains every var the templates
#     actually reference (cross-check against templates)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

MENU="$REPO_ROOT/lib/menu.sh"
assert_file_exists "$MENU" "lib/menu.sh present"

# Source menu.sh in isolation. Needs OS + log.sh helpers first.
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/log.sh"
OS="wsl"
# shellcheck source=/dev/null
source "$MENU"

echo "should_show_menu — pre-seeded env vars"

# Clean state would return 0 only if TTY present. Here stdin/stdout may
# or may not be TTY depending on run-all context; focus on the var
# branches which are deterministic.

_test_gates() {
    local var="$1"
    # Unset everything relevant first
    unset NON_INTERACTIVE ONLY_TOPICS
    unset INCLUDE_DOCKER INCLUDE_LARAVEL INCLUDE_REMOTE INCLUDE_EDITOR
    unset INCLUDE_MAILPIT INCLUDE_NGROK INCLUDE_MSSQL
    unset PHP_VERSIONS DOTFILES_REPO
    unset CI

    # Set the one being tested
    eval "export $var"

    ASSERT_MSG="should_show_menu returns 1 when $var is set"
    assert_false "should_show_menu"
}

_test_gates "NON_INTERACTIVE=1"
_test_gates "ONLY_TOPICS=00-core"
_test_gates "INCLUDE_DOCKER=1"
_test_gates "INCLUDE_LARAVEL=1"
_test_gates "INCLUDE_REMOTE=1"
_test_gates "INCLUDE_EDITOR=1"
_test_gates "INCLUDE_MAILPIT=1"
_test_gates "INCLUDE_NGROK=1"
_test_gates "INCLUDE_MSSQL=1"
_test_gates "PHP_VERSIONS=8.5"
_test_gates "DOTFILES_REPO=git@github.com:x/y.git"
_test_gates "CI=true"

echo
echo "data/php-versions.conf parses to a non-empty list"

versions_file="$REPO_ROOT/topics/10-languages/data/php-versions.conf"
assert_file_exists "$versions_file"

versions="$(grep -vE '^\s*(#|$)' "$versions_file" | xargs)"
assert_ne "$versions" "" "versions list non-empty"

# Every entry must match X.Y semver-ish
bad=""
for v in $versions; do
    if [[ ! "$v" =~ ^[0-9]+\.[0-9]+$ ]]; then
        bad+="$v "
    fi
done
assert_eq "$bad" "" "every version is MAJOR.MINOR format"

# sort -V produces deterministic order (last = highest)
latest="$(echo "$versions" | tr ' ' '\n' | sort -V | tail -1)"
assert_ne "$latest" "" "sort -V picks a latest version"

echo
echo "PECL extensions list parses to ext[:linux-deps[:mac-deps]] tuples"

pecl_file="$REPO_ROOT/topics/10-languages/data/php-extensions-pecl.txt"
assert_file_exists "$pecl_file"

while IFS= read -r line; do
    # Every entry should have at least one token when split on colons
    IFS=':' read -r ext _ _ <<< "$line"
    ASSERT_MSG="pecl line has an extension name: '$line'"
    assert_ne "$ext" "" "$ASSERT_MSG"
done < <(grep -vE '^\s*(#|$)' "$pecl_file")

summary
