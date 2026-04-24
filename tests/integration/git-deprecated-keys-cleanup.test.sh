#!/usr/bin/env bash
# tests/integration/git-deprecated-keys-cleanup.test.sh
#
# Regression: ensure 50-git still has the deprecated-keys cleanup mechanism.
#
# Without it, removing a key from data/gitconfig.keys silently leaves the
# value persisted in ~/.gitconfig on every machine that already had it
# applied — install.sh is additive-only, so removed keys never get cleaned.
# The user has to remember to `git config --global --unset KEY` on each
# machine, which is exactly what this mechanism exists to avoid.
#
# This test is grep-based (no actual git config mutation) — fast and
# deterministic. It checks:
#   1. data/gitconfig.removed exists (the deprecation manifest)
#   2. install.sh reads it and runs `git config --global --unset` per entry
#   3. The unset path has the same user.*/credential.* protection as the
#      install path (we never want to unset identity by accident)
#   4. Idempotency guard (`|| true` on the unset call) is present

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

INSTALL="$ROOT/topics/50-git/install.sh"
REMOVED_FILE="$ROOT/topics/50-git/data/gitconfig.removed"

assert_file_exists() {
    local file="$1" msg="$2"
    if [[ -f "$file" ]]; then
        pass "$msg"
    else
        fail "$msg (file not found: $file)"
    fi
}

assert_file_contains() {
    local file="$1" pattern="$2" msg="$3"
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' not in $file)"
    fi
}

echo
echo "═══ deprecated-keys cleanup mechanism (drift management for git config) ═══"

assert_file_exists "$REMOVED_FILE" "data/gitconfig.removed exists"
assert_file_exists "$INSTALL"      "install.sh exists"

assert_file_contains "$INSTALL" 'gitconfig\.removed' \
    "install.sh references data/gitconfig.removed"

assert_file_contains "$INSTALL" 'git config --global --unset' \
    "install.sh has the --unset call (drift cleanup)"

assert_file_contains "$INSTALL" '\|\|[[:space:]]*true' \
    "install.sh uses '|| true' to swallow exit 5 from --unset on absent keys (idempotency)"

# Same user.*/credential.* protection as the install loop — never auto-unset identity
unset_block=$(awk '/removed_file=/,/^fi$/' "$INSTALL")
if grep -qE 'user\.\*\|credential\.\*' <<<"$unset_block"; then
    pass "unset loop protects user.* and credential.* (won't blow away identity)"
else
    fail "unset loop missing user.*/credential.* protection — risk of unsetting user.email by mistake"
fi

# Comment in gitconfig.keys points users to the new mechanism (so future
# maintainers know to dual-edit when removing a key)
KEYS_FILE="$ROOT/topics/50-git/data/gitconfig.keys"
assert_file_contains "$KEYS_FILE" 'gitconfig\.removed' \
    "gitconfig.keys comment references gitconfig.removed (dual-edit guidance)"

summary
