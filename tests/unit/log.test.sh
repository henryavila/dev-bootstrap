#!/usr/bin/env bash
# Unit tests for scripts/lib/log.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1091
. "$WS/scripts/lib/log.sh"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        passed=$((passed+1)); echo "  ✓ $name"
    else
        failed=$((failed+1)); echo "  ✗ $name (expected: $expected, got: $actual)" >&2
    fi
}

# log_info prints to stderr with [INFO] prefix
out=$(log_info "hello" 2>&1 1>/dev/null)
assert "log_info prefix"   "[INFO] hello"  "$out"

out=$(log_warn "danger" 2>&1 1>/dev/null)
assert "log_warn prefix"   "[WARN] danger" "$out"

out=$(log_error "boom" 2>&1 1>/dev/null)
assert "log_error prefix"  "[ERROR] boom"  "$out"

# shellcheck disable=SC2034  # read by log_debug (sourced from log.sh)
# log_debug suppressed unless MESH_DEBUG=1
unset MESH_DEBUG
out=$(log_debug "hidden" 2>&1 1>/dev/null)
assert "log_debug suppressed" "" "$out"

MESH_DEBUG=1
out=$(log_debug "shown" 2>&1 1>/dev/null)
assert "log_debug enabled"    "[DEBUG] shown" "$out"

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
