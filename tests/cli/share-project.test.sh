#!/usr/bin/env bash
# tests/cli/share-project.test.sh — share-project degrades gracefully
# when ngrok isn't installed / authtoken is missing.
#
# We can't actually tunnel anything in tests (network + auth required),
# but we CAN verify:
#   - script exits non-zero + points at install docs when ngrok is absent
#   - --help prints usage without error

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SHARE="$REPO_ROOT/topics/60-web-stack/templates/bin/share-project.template"
assert_file_exists "$SHARE"

echo "--help / -h prints usage with zero exit"
assert_exit_code 0 "bash '$SHARE' --help"
assert_exit_code 0 "bash '$SHARE' -h"

echo
echo "missing ngrok → non-zero exit + install instructions"

# Capture output AND exit code separately — `|| true` in command
# substitution masks $? via command-substitution semantics. Use a
# two-step pattern: run, capture code, then capture output.
rc_noNgrok=0
env PATH='/usr/bin:/bin' bash "$SHARE" somesite >/dev/null 2>&1 || rc_noNgrok=$?
assert_ne "$rc_noNgrok" "0" "exits non-zero when ngrok absent"

out_noNgrok="$(env PATH='/usr/bin:/bin' bash "$SHARE" somesite 2>&1 || true)"
assert_contains "$out_noNgrok" "ngrok" "mentions ngrok in error"
assert_contains "$out_noNgrok" "INCLUDE_NGROK" "points at re-running bootstrap with INCLUDE_NGROK"

echo
echo "no site name passed → usage+exit 1"

rc_empty=0
PATH='/usr/bin:/bin' bash "$SHARE" --port 3000 >/dev/null 2>&1 || rc_empty=$?
assert_ne "$rc_empty" "0" "no site name → exits non-zero"

summary
