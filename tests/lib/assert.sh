# tests/lib/assert.sh — shared assertion helpers for every *.test.sh.
#
# Source this at the top of each test file. It sets:
#   PASS=0 FAIL=0
# and exposes:
#   assert_eq "actual" "expected" "message"
#   assert_ne "actual" "unexpected" "message"
#   assert_true "command [args]"            # command must exit 0
#   assert_false "command [args]"           # command must exit != 0
#   assert_exit_code <expected> "command [args]"
#   assert_contains "haystack" "needle" "message"
#   assert_not_contains "haystack" "needle" "message"
#   assert_file_exists "path" "message"
#   assert_file_contains "path" "pattern" "message"
#   pass "msg"   — manual pass note
#   fail "msg"   — manual fail note
#   summary      — print PASS/FAIL counts; exit 1 if any FAIL
#
# Each assertion prints a ✓ or ✗ line and increments the respective counter.
# Tests typically end with `summary` so the run-all orchestrator gets a
# clean exit code.

# shellcheck shell=bash
set -uo pipefail   # no -e — we want failing assertions to accumulate

PASS=0
FAIL=0

_c_ok='\033[32m'
_c_err='\033[31m'
_c_dim='\033[2m'
_c_reset='\033[0m'
if [[ ! -t 1 ]] || [[ -n "${NO_COLOR:-}" ]]; then
    _c_ok=""; _c_err=""; _c_dim=""; _c_reset=""
fi

pass() {
    PASS=$((PASS + 1))
    printf "  ${_c_ok}✓${_c_reset} %s\n" "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf "  ${_c_err}✗${_c_reset} %s\n" "$1" >&2
}

assert_eq() {
    local actual="$1" expected="$2" msg="${3:-values match}"
    if [[ "$actual" == "$expected" ]]; then
        pass "$msg"
    else
        fail "$msg"
        printf "      expected: %q\n      actual:   %q\n" "$expected" "$actual" >&2
    fi
}

assert_ne() {
    local actual="$1" unexpected="$2" msg="${3:-values differ}"
    if [[ "$actual" != "$unexpected" ]]; then
        pass "$msg"
    else
        fail "$msg (both were $(printf '%q' "$actual"))"
    fi
}

assert_true() {
    local cmd="$*"
    local msg="${ASSERT_MSG:-$cmd}"
    if eval "$cmd" >/dev/null 2>&1; then
        pass "$msg"
    else
        fail "$msg (command failed: $cmd)"
    fi
}

assert_false() {
    local cmd="$*"
    local msg="${ASSERT_MSG:-!$cmd}"
    if eval "$cmd" >/dev/null 2>&1; then
        fail "$msg (command unexpectedly succeeded: $cmd)"
    else
        pass "$msg"
    fi
}

assert_exit_code() {
    local expected="$1"
    shift
    local cmd="$*"
    local msg="${ASSERT_MSG:-exit code $expected from: $cmd}"
    local actual
    eval "$cmd" >/dev/null 2>&1
    actual=$?
    if [[ "$actual" -eq "$expected" ]]; then
        pass "$msg"
    else
        fail "$msg (got $actual)"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-contains substring}"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$msg"
    else
        fail "$msg"
        printf "      looking for: %q\n      in:          %q\n" "$needle" "$haystack" >&2
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-does not contain substring}"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$msg"
    else
        fail "$msg"
        printf "      found unwanted: %q\n" "$needle" >&2
    fi
}

assert_file_exists() {
    local path="$1" msg="${2:-file exists: $1}"
    if [[ -f "$path" ]]; then
        pass "$msg"
    else
        fail "$msg (missing)"
    fi
}

assert_file_contains() {
    local path="$1" pattern="$2"
    local msg="${3:-$path contains pattern}"
    if [[ ! -f "$path" ]]; then
        fail "$msg (file missing: $path)"
        return
    fi
    if grep -q "$pattern" "$path" 2>/dev/null; then
        pass "$msg"
    else
        fail "$msg"
        printf "      pattern:  %q\n      in file:  %s\n" "$pattern" "$path" >&2
    fi
}

# Grep-ERE variants — take (file, pattern, msg). Preferred over
# assert_file_contains for new tests because ERE is more expressive
# and the argument order matches the other assert_pattern_* helpers.
assert_pattern_present() {
    local file="$1" pattern="$2"
    local msg="${3:-$file contains pattern}"
    if [[ ! -f "$file" ]]; then
        fail "$msg (file missing: $file)"
        return
    fi
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' not found in $file)"
    fi
}

assert_pattern_absent() {
    local file="$1" pattern="$2"
    local msg="${3:-$file does not contain pattern}"
    if [[ ! -f "$file" ]]; then
        fail "$msg (file missing: $file)"
        return
    fi
    if ! grep -qE "$pattern" "$file" 2>/dev/null; then
        pass "$msg"
    else
        local first_match
        first_match="$(grep -nE "$pattern" "$file" 2>/dev/null | head -1)"
        fail "$msg (anti-pattern '$pattern' found in $file)"
        printf "              first matches:\n        %s\n" "$first_match" >&2
    fi
}

summary() {
    local total=$((PASS + FAIL))
    printf "\n"
    if [[ "$FAIL" -eq 0 ]]; then
        printf "${_c_ok}%d/%d passed${_c_reset}\n" "$PASS" "$total"
    else
        printf "${_c_err}%d/%d failed${_c_reset}\n" "$FAIL" "$total"
        exit 1
    fi
}
