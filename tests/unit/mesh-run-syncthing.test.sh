#!/usr/bin/env bash
# Unit test for the `mesh run` syncthing fan-out wiring (T-002):
#   - the allowlist accepts `syncthing pair|status` and rejects mutating verbs
#     (password / init-hub / topology) — validation runs before any host/ssh work
#   - the fan-out command is forced NON_INTERACTIVE for syncthing so a pending
#     Tier-0 device approve defers instead of hanging the sweep
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
MESH="$WS/bin/mesh"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected [$expected], got [$actual])" >&2; fi
}
assert_contains() {
    local name="$1" needle="$2" hay="$3"
    if [[ "$hay" == *"$needle"* ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (missing [$needle])" >&2; fi
}
assert_not_contains() {
    local name="$1" needle="$2" hay="$3"
    if [[ "$hay" != *"$needle"* ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (unexpected [$needle])" >&2; fi
}

# ── pure helpers: awk-extract so we skip bin/mesh's heavy top-level ──
extract() { awk "/^$1\\(\\) \\{/{c=1} c{print} c&&/^}/{exit}" "$MESH"; }
eval "$(extract _mesh_quote_args)"
eval "$(extract _run_force_noninteractive)"
eval "$(extract _mesh_remote_command)"

# _run_force_noninteractive: only syncthing forces it
yn() { "$@" && echo yes || echo no; }
assert "force-ni: syncthing → yes" "yes" "$(yn _run_force_noninteractive syncthing)"
assert "force-ni: status    → no"  "no"  "$(yn _run_force_noninteractive status)"
assert "force-ni: update    → no"  "no"  "$(yn _run_force_noninteractive update)"

# remote command string: syncthing carries the non-interactive export, others don't
st_cmd="$(_mesh_remote_command syncthing pair)"
assert_contains "remote: syncthing exports NON_INTERACTIVE" "NON_INTERACTIVE=1" "$st_cmd"
assert_contains "remote: invokes mesh syncthing pair"       "mesh syncthing pair" "$st_cmd"
status_cmd="$(_mesh_remote_command status --write)"
assert_not_contains "remote: status has no NON_INTERACTIVE"  "NON_INTERACTIVE=1" "$status_cmd"

# ── allowlist enforcement (dies before host/ssh work, so no network needed) ──
out="$(bash "$MESH" run --all syncthing password 2>&1)"; rc=$?
assert "reject 'syncthing password' (rc!=0)" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert_contains "reject names the safe verbs" "can fan out" "$out"

out="$(bash "$MESH" run --all syncthing topology 2>&1)"
assert_contains "reject 'syncthing topology'" "can fan out" "$out"

out="$(bash "$MESH" run --all frobnicate 2>&1)"
assert_contains "reject unknown subcommand" "unsupported mesh subcommand" "$out"

out="$(bash "$MESH" run 2>&1)"
assert_contains "missing-subcommand msg lists syncthing" "syncthing pair|status" "$out"

# ── acceptance: `syncthing pair` passes validation (dry-run, no ssh) ──
out="$(bash "$MESH" run --hosts mac --dry-run syncthing pair 2>&1)"; rc=$?
assert "accept 'syncthing pair' (rc0)" "0" "$rc"
assert_contains "dry-run shows the fan-out command" "syncthing pair" "$out"

echo
echo "mesh-run-syncthing: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
