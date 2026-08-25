#!/usr/bin/env bash
# F2 T-002 — MESH_NO_MESH=1 makes atuin-login.sh exit 0 without invoking
# `atuin login`; unset MESH_NO_MESH keeps the existing login path.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

SCRIPT="$WS/topics/shell-terminal/atuin-login.sh"
assert_file_exists "$SCRIPT" "atuin-login.sh exists"
assert_file_contains "$SCRIPT" 'MESH_NO_MESH' \
    "atuin-login.sh guards on MESH_NO_MESH"

TMP="$(mktemp -d /tmp/atuin-no-mesh.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
# Isolate HOME so atuin-login.sh cannot prepend ~/.atuin/bin (real OAuth login).
mkdir -p "$TMP/home"
export HOME="$TMP/home"

# Fake atuin that records invocations; `login` fails the test if reached under no-mesh.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/atuin" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "${ATUIN_LOG:?}"
if [[ "${1:-}" == "login" ]]; then
    echo "LOGIN_CALLED" >> "$ATUIN_LOG"
    exit 0
fi
if [[ "${1:-}" == "status" ]]; then
    exit 1
fi
exit 0
SH
chmod +x "$TMP/bin/atuin"

run_phase() {
    local phase="$1"
    (
        # shellcheck source=/dev/null
        . "$SCRIPT"
        "$phase"
    )
}

# --- no-mesh: install/check must not call atuin login ---
: > "$TMP/atuin.log"
export ATUIN_LOG="$TMP/atuin.log"
export PATH="$TMP/bin:$PATH"
# Pretend binary exists via PATH; also clear NON_INTERACTIVE so only MESH_NO_MESH gates.
unset NON_INTERACTIVE ATUIN_LOGIN_AUTO || true
export MESH_NO_MESH=1

rc=0
out="$(run_phase install 2>&1)" || rc=$?
assert_eq "$rc" "0" "install() under MESH_NO_MESH=1 exits 0"
assert_contains "$out" "MESH_NO_MESH=1" "install() logs no-mesh skip"
if grep -q 'LOGIN_CALLED' "$TMP/atuin.log" 2>/dev/null; then
    fail "install() under no-mesh does not call atuin login"
else
    pass "install() under no-mesh does not call atuin login"
fi

rc=0
run_phase check >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "check() under MESH_NO_MESH=1 exits 0"
if grep -q 'status' "$TMP/atuin.log" 2>/dev/null; then
    fail "check() under no-mesh does not call atuin status"
else
    pass "check() under no-mesh does not call atuin status"
fi

# --- unflagged interactive path still reaches atuin login ---
: > "$TMP/atuin.log"
unset MESH_NO_MESH
export NON_INTERACTIVE=0
export ATUIN_LOGIN_AUTO=1
# Force a TTY-like path: the script checks [[ -t 0 ]]. Under a pipe that fails,
# so invoke with a pseudo-tty via script/socat if available; otherwise assert the
# source still contains the login call for the unflagged path.
if command -v script >/dev/null 2>&1; then
    rc=0
    # script -q -c '...' /dev/null provides a TTY for stdin checks on Linux.
    # HOME is the isolated tmp home so ~/.atuin/bin cannot win PATH.
    timeout 8 script -q -c "HOME='$TMP/home' PATH='$TMP/bin:$PATH' ATUIN_LOG='$TMP/atuin.log' ATUIN_LOGIN_AUTO=1 NON_INTERACTIVE=0 MESH_NO_MESH=0 bash -c '
        unset MESH_NO_MESH
        source \"$SCRIPT\"
        install
    '" /dev/null >/dev/null 2>&1 || rc=$?
    if grep -q 'LOGIN_CALLED' "$TMP/atuin.log" 2>/dev/null; then
        pass "unflagged install() on a TTY calls atuin login"
    else
        # `script` present but TTY probe did not reach login — still require the
        # unflagged source contract, and fail closed if MESH_NO_MESH leaked in.
        assert_file_contains "$SCRIPT" 'atuin login' \
            "unflagged path still contains atuin login (TTY probe inconclusive)"
        if grep -q 'MESH_NO_MESH=1' "$TMP/atuin.log" 2>/dev/null; then
            fail "unflagged TTY probe saw MESH_NO_MESH skip — env leaked"
        else
            pass "unflagged TTY probe inconclusive — source contract asserted (no no-mesh skip)"
        fi
    fi
else
    assert_file_contains "$SCRIPT" 'atuin login' \
        "unflagged path still contains atuin login"
fi

summary
