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
# Source log helpers before assert.sh so assert.sh owns pass/fail counters.
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/log.sh"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

MENU="$REPO_ROOT/lib/menu.sh"
DOTFILES_TOPIC="$REPO_ROOT/topics/95-dotfiles-personal/install.sh"
BOOTSTRAP="$REPO_ROOT/bootstrap.sh"
assert_file_exists "$MENU" "lib/menu.sh present"
assert_file_exists "$DOTFILES_TOPIC" "95-dotfiles-personal install.sh present"
assert_file_exists "$BOOTSTRAP" "bootstrap.sh present"

# Source menu.sh in isolation. Needs OS + log.sh helpers first.
# shellcheck disable=SC2034 # consumed by lib/menu.sh after source
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
    unset PHP_VERSIONS DOTFILES_REPO DOTFILES_NPM_GLOBAL
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
_test_gates "DOTFILES_NPM_GLOBAL=1"
_test_gates "CI=true"

echo
echo "npm global opt-in is first-class in the interactive menu"

assert_pattern_present "$MENU" '^[[:space:]]*"npm-global"[[:space:]]+"95-dotfiles-personal: npm globals under ~/.npm-global"' \
    "menu checklist shows npm-global opt-in"

assert_pattern_present "$MENU" 'npm-global\) export DOTFILES_NPM_GLOBAL=1' \
    "menu selection exports DOTFILES_NPM_GLOBAL"

assert_file_contains "$MENU" 'DOTFILES_NPM_GLOBAL:-0\}" == "1" \]\] *&& return 1' \
    "should_show_menu treats DOTFILES_NPM_GLOBAL as a pre-seed signal"

assert_file_contains "$MENU" "echo 'export DOTFILES_NPM_GLOBAL=1'" \
    "_persist_menu_state persists DOTFILES_NPM_GLOBAL"

_test_persist_npm_global() {
    local enabled="$1"
    bash -c "
        set -uo pipefail
        TMP=\$(mktemp -d)
        export BOOTSTRAP_STATE_CONFIG=\"\$TMP/config.env\"
        export DOTFILES_NPM_GLOBAL='$enabled'
        ok()   { :; }
        info() { :; }
        warn() { :; }
        fail() { :; }
        # shellcheck disable=SC1091
        source '$MENU' 2>/dev/null || true
        _persist_menu_state
        cat \"\$BOOTSTRAP_STATE_CONFIG\" 2>/dev/null
        rm -rf \"\$TMP\"
    "
}

npm_global_state="$(_test_persist_npm_global 1)"
assert_contains "$npm_global_state" "export DOTFILES_NPM_GLOBAL=1" \
    "_persist_menu_state round-trips npm global opt-in when enabled"

npm_global_state="$(_test_persist_npm_global 0)"
assert_not_contains "$npm_global_state" "DOTFILES_NPM_GLOBAL" \
    "_persist_menu_state omits npm global opt-in when disabled"

assert_pattern_present "$DOTFILES_TOPIC" 'DOTFILES_NPM_GLOBAL="\$\{DOTFILES_NPM_GLOBAL:-0\}" bash "\$DOTFILES_DIR/install.sh"' \
    "95-dotfiles-personal forwards DOTFILES_NPM_GLOBAL to dotfiles install.sh"

echo
echo "macOS menu dependencies"

_test_mac_menu_bootstraps_brew_when_whiptail_needs_homebrew() {
    local tmp fake_root marker
    tmp="$(mktemp -d)"
    fake_root="$tmp/dev-bootstrap"
    marker="$tmp/00-core-ran"
    mkdir -p "$fake_root/topics/00-core" "$fake_root/lib" "$tmp/homebrew/bin" "$tmp/bin"
    local bash_bin
    bash_bin="$(command -v bash)"
    ln -s "$bash_bin" "$tmp/bin/bash"

    cat > "$fake_root/topics/00-core/install.mac.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo ran > "$marker"
EOF
    chmod +x "$fake_root/topics/00-core/install.mac.sh"

    cat > "$tmp/homebrew/bin/brew" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--prefix" ]]; then
    printf '%s\n' "$tmp/homebrew"
    exit 0
fi
exit 0
EOF
    chmod +x "$tmp/homebrew/bin/brew"

    cat > "$fake_root/lib/detect-brew.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'BREW_BIN=%q\n' "$tmp/homebrew/bin/brew"
printf 'BREW_PREFIX=%q\n' "$tmp/homebrew"
EOF
    chmod +x "$fake_root/lib/detect-brew.sh"

    local old_path="$PATH"
    PATH="$tmp/bin"
    OS="mac"
    BREW_BIN=""
    BREW_PREFIX=""
    DEV_BOOTSTRAP_ROOT="$fake_root"

    prepare_interactive_menu_dependencies

    assert_eq "$(<"$marker")" "ran" "mac menu prereq runs 00-core before whiptail when brew is missing"
    assert_eq "$BREW_BIN" "$tmp/homebrew/bin/brew" "mac menu prereq refreshes BREW_BIN after 00-core"
    assert_eq "$BREW_PREFIX" "$tmp/homebrew" "mac menu prereq refreshes BREW_PREFIX after 00-core"

    PATH="$old_path"
    rm -rf "$tmp"
}

_test_mac_menu_bootstraps_brew_when_whiptail_needs_homebrew

assert_pattern_present "$BOOTSTRAP" 'prepare_interactive_menu_dependencies' \
    "bootstrap prepares macOS menu dependencies before ensure_whiptail"
prepare_line="$(grep -n 'prepare_interactive_menu_dependencies' "$BOOTSTRAP" | head -1 | cut -d: -f1)"
ensure_line="$(grep -n 'ensure_whiptail' "$BOOTSTRAP" | head -1 | cut -d: -f1)"
if [[ -n "$prepare_line" && -n "$ensure_line" && "$prepare_line" -lt "$ensure_line" ]]; then
    pass "bootstrap prepares dependencies before calling ensure_whiptail"
else
    fail "bootstrap prepares dependencies before calling ensure_whiptail"
fi

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
