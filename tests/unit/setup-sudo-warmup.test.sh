#!/usr/bin/env bash
# setup.sh sudo warmup must not hang headless WSL (pts + password-required %sudo).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

SETUP="$WS/setup.sh"
assert_file_exists "$SETUP" "setup.sh exists"

block="$(awk '
  /sudo warmup \+ legacy NOPASSWD cleanup/ {on=1}
  on {print}
  on && /legacy_nopasswd=/ {exit}
' "$SETUP")"

assert_contains "$block" 'sudo -n -v' \
  "non-interactive/no-TTY warmup uses sudo -n -v (fail-fast, no password prompt)"
assert_contains "$block" 'NON_INTERACTIVE' \
  "warmup branches on NON_INTERACTIVE"
assert_contains "$block" 'sudo -v' \
  "interactive TTY warmup still uses sudo -v"

# The hang we hit on clean WSL: password-prompting sudo validate on a pts
# with no operator. Ignore comments; only flag a live command.
if printf '%s\n' "$block" | grep -vE '^[[:space:]]*#' | grep -qE 'sudo -v 2>/dev/null'; then
  fail "warmup must not hide sudo -v behind 2>/dev/null (prompt-less hang on WSL pts)"
else
  pass "warmup does not use hidden sudo -v 2>/dev/null"
fi

summary
