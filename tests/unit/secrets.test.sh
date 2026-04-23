#!/usr/bin/env bash
# tests/unit/secrets.test.sh — lib/secrets.sh helper contract.
#
# Contract under test (see lib/secrets.sh header):
#   - secrets_init creates $BOOTSTRAP_SECRETS_FILE with mode 0600, parent 0700.
#   - secrets_load sources the file when mode is 0600 or 0400, refuses if loose
#     and chmod failed, no-op when file is absent.
#   - secrets_set upserts atomically; refuses newline-containing values.
#   - secrets_has returns 0 iff the key is in env OR present in the file.
#
# Notes on isolation:
#   We override BOOTSTRAP_STATE_DIR per test so each assertion operates on a
#   fresh tmp tree — avoids cross-test leaks and keeps the runner idempotent
#   even when executed against a real user that already has secrets on disk.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SECRETS_SH="$REPO_ROOT/lib/secrets.sh"
assert_file_exists "$SECRETS_SH" "lib/secrets.sh present"

# Each test gets a fresh state dir. mktemp -d works the same way on
# macOS + GNU; the `-t` prefix spelling is portable.
_fresh_state() {
    local tmp
    tmp="$(mktemp -d -t dev-bootstrap-secrets-test.XXXXXX)"
    export BOOTSTRAP_STATE_DIR="$tmp"
    export BOOTSTRAP_SECRETS_FILE="$tmp/secrets.env"
    # shellcheck source=/dev/null
    source "$SECRETS_SH"
}

# Helper: read permission octal in a cross-platform way, mirroring the
# lib's own _secrets_mode so the test isn't tied to one of stat's dialects.
_mode_of() {
    stat -c '%a' "$1" 2>/dev/null \
        || stat -f '%A' "$1" 2>/dev/null \
        || perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$1" 2>/dev/null
}

echo
echo "== secrets_init =="
_fresh_state
secrets_init
assert_file_exists "$BOOTSTRAP_SECRETS_FILE" "secrets.env created on init"
mode="$(_mode_of "$BOOTSTRAP_SECRETS_FILE")"
assert_eq "$mode" "600" "secrets.env mode is 0600"
dir_mode="$(_mode_of "$BOOTSTRAP_STATE_DIR")"
assert_eq "$dir_mode" "700" "state dir mode is 0700"

# Calling init twice must not change or truncate the file.
echo "NOT_A_REAL_KEY=marker" >> "$BOOTSTRAP_SECRETS_FILE"
secrets_init
assert_true "grep -q NOT_A_REAL_KEY '$BOOTSTRAP_SECRETS_FILE'" \
    "secrets_init is idempotent — does not clobber existing content"

echo
echo "== secrets_set =="
_fresh_state
secrets_set NGROK_AUTHTOKEN "sk_test_123 with space"
assert_file_exists "$BOOTSTRAP_SECRETS_FILE" "secrets.env exists after set"
assert_true "grep -qE '^export NGROK_AUTHTOKEN=' '$BOOTSTRAP_SECRETS_FILE'" \
    "file contains the set key"

# Upsert semantics — second set must replace the first, not duplicate.
secrets_set NGROK_AUTHTOKEN "sk_test_456"
count="$(grep -cE '^export NGROK_AUTHTOKEN=' "$BOOTSTRAP_SECRETS_FILE")"
assert_eq "$count" "1" "secrets_set upserts (one line per key after update)"

# Value round-trips through printf %q — special chars preserved.
unset NGROK_AUTHTOKEN
# shellcheck source=/dev/null
source "$BOOTSTRAP_SECRETS_FILE"
assert_eq "${NGROK_AUTHTOKEN:-}" "sk_test_456" "value round-trips through set+source"

# Newline-containing values must be rejected.
if secrets_set BAD_KEY "$(printf 'line1\nline2')" 2>/dev/null; then
    fail "secrets_set must refuse newline-containing values"
else
    pass "secrets_set refuses newline-containing values"
fi

echo
echo "== secrets_has =="
_fresh_state
unset FOO BAR
if secrets_has FOO; then
    fail "secrets_has returns 1 for absent key"
else
    pass "secrets_has returns 1 for absent key"
fi

secrets_set FOO "bar"
if secrets_has FOO; then
    pass "secrets_has returns 0 for key in file"
else
    fail "secrets_has returns 0 for key in file"
fi

# Env wins over file — exported value counts even if file absent.
_fresh_state
export BAR="env-value"
if secrets_has BAR; then
    pass "secrets_has returns 0 when key is in env only"
else
    fail "secrets_has returns 0 when key is in env only"
fi
unset BAR

echo
echo "== secrets_load =="
_fresh_state
# Absent file — no-op, returns 0.
unset LOAD_KEY
if secrets_load; then
    pass "secrets_load succeeds when file is absent"
else
    fail "secrets_load should succeed when file is absent"
fi

# Present + 0600 file — sourced.
secrets_set LOAD_KEY "load-value"
unset LOAD_KEY
secrets_load
assert_eq "${LOAD_KEY:-}" "load-value" "secrets_load sources 0600 file"

# Loose permissions — function must tighten then load.
_fresh_state
secrets_set LOOSE_KEY "loose-value"
chmod 0644 "$BOOTSTRAP_SECRETS_FILE"
unset LOOSE_KEY
secrets_load
mode_after="$(_mode_of "$BOOTSTRAP_SECRETS_FILE")"
assert_eq "$mode_after" "600" "secrets_load tightens loose permissions back to 0600"
assert_eq "${LOOSE_KEY:-}" "loose-value" "secrets_load still sources after tightening"

# Cleanup
rm -rf "$BOOTSTRAP_STATE_DIR"

summary
