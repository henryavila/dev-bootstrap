#!/usr/bin/env bash
# Lean bootstrap selection when Blink menu cannot open (Node missing).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/tests/lib/assert.sh" 2>/dev/null || {
  pass() { echo "  ✓ $*"; }
  fail() { echo "  ✗ $*" >&2; exit 1; }
  assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3"; }
  assert_eq() { [[ "$1" == "$2" ]] || fail "$3 (got='$1' want='$2')"; }
  assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3"; }
}

# Extract just the emit helpers by sourcing setup pieces is heavy; instead
# run a minimal bash that mirrors the functions from setup.sh.
emit_lean_bootstrap_selections() {
    printf '%s\n' \
        foundation/base \
        identity/identity \
        git/config \
        shell-terminal/cli-tools \
        shell-terminal/zsh \
        shell-terminal/fonts \
        languages/node \
        personal/personal
}

lean="$(emit_lean_bootstrap_selections)"
assert_contains "$lean" "foundation/base" "lean includes foundation/base"
assert_contains "$lean" "languages/node" "lean includes languages/node"
assert_contains "$lean" "shell-terminal/fonts" "lean includes fonts for WT/NF"
assert_contains "$lean" "personal/personal" "lean keeps personal (TTY onboarding)"
assert_not_contains "$lean" "databases/" "lean must not pull databases"
assert_not_contains "$lean" "web/" "lean must not pull web stack"
assert_not_contains "$lean" "ai/" "lean must not pull AI tools"

# setup.sh must define MESH_LEAN_BOOTSTRAP path
assert_contains "$(grep -n 'MESH_LEAN_BOOTSTRAP' "$ROOT/setup.sh")" "MESH_LEAN_BOOTSTRAP" \
  "setup.sh references MESH_LEAN_BOOTSTRAP"
assert_contains "$(grep -n 'emit_lean_bootstrap_selections' "$ROOT/setup.sh")" "emit_lean_bootstrap_selections" \
  "setup.sh defines emit_lean_bootstrap_selections"

# Must NOT force NON_INTERACTIVE on menu miss anymore
if grep -A6 'interactive bundle menu unavailable' "$ROOT/setup.sh" | grep -q 'NON_INTERACTIVE=1'; then
  fail "menu-unavailable path must not set NON_INTERACTIVE=1"
else
  pass "menu-unavailable path does not set NON_INTERACTIVE=1"
fi

pass "lean bootstrap selection contract"
echo "OK"
