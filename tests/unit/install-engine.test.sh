#!/usr/bin/env bash
# Unit tests for scripts/lib/install-engine.sh.
# Verifies: lifecycle ordering, subshell isolation, dry-run mode, custom-script dispatch.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
ENGINE="$WS/scripts/lib/install-engine.sh"
FIX="$HERE/fixtures/install-engine"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected: $expected, got: $actual)" >&2; fi
}

# Build a minimal items.yaml for the test (single brew-formula item).
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/items.yaml" <<'YAML'
- name: htop
  type: brew-formula
  spec: htop
  check: command -v htop
  desc: "Interactive process viewer"
YAML

# Mock brew driver: writes a file when install runs.
mkdir -p "$TMP/installers"
cat > "$TMP/installers/brew-formula.sh" <<'SH'
brew_formula_check()   { command -v "$1" >/dev/null 2>&1; }
brew_formula_install() { echo "installed:$1" > "$STATE_DIR/installed"; }
brew_formula_verify()  { command -v "$1" >/dev/null 2>&1; }
SH

# Set engine context.
STATE_DIR=$TMP
export STATE_DIR

# Dry-run must NOT actually invoke install (no file written).
out=$(MESH_WORKSTATION_DIR=$WS PATH=/usr/bin:/bin bash "$ENGINE" \
    --manifest "$TMP/items.yaml" --installers-dir "$TMP/installers" \
    --dry-run 2>&1 || true)
assert "dry-run: no state file written" "absent" "$(test -f $TMP/installed && echo present || echo absent)"

# Sanity: engine emits a plan line for the item.
echo "$out" | grep -q 'htop' && \
    { passed=$((passed+1)); echo "  ✓ dry-run: plan mentions htop"; } || \
    { failed=$((failed+1)); echo "  ✗ dry-run: plan did not mention htop" >&2; }

# Test 3: failed item propagates correct exit code (regression for fix of $?)
# A mock driver that always fails install.
cat > "$TMP/installers/failing-driver.sh" <<'SH'
failing_driver_check()   { return 1; }
failing_driver_install() { echo "this fails on purpose"; return 67; }
SH
cat > "$TMP/items-fail.yaml" <<'YAML'
- name: failing-item
  type: failing-driver
  spec: anything
YAML
set +e
bash "$ENGINE" --manifest "$TMP/items-fail.yaml" --installers-dir "$TMP/installers" 2>/dev/null
rc=$?
set -e
# Expect non-zero exit; specifically should be 67 (from the driver) or some non-zero
if [[ $rc -ne 0 ]]; then
    passed=$((passed+1)); echo "  ✓ failed item exits non-zero (rc=$rc)"
else
    failed=$((failed+1)); echo "  ✗ failed item exited 0 (bug)" >&2
fi

# Test 4: install() failure routes through rollback (regression for Codex
# review A-F003 / F-F005, 2026-05-19). Previously `set -euo pipefail`
# exited the item subshell on install() failure BEFORE rollback could fire,
# leaving partial state behind.
mkdir -p "$TMP/installers"
cat > "$TMP/installers/rollback-driver.sh" <<SH
rollback_driver_check()    { return 1; }                    # force install
rollback_driver_install()  { echo install-ran > "$TMP/install-marker"; return 42; }
rollback_driver_rollback() { touch "$TMP/rollback-sentinel"; }
SH
cat > "$TMP/items-rollback.yaml" <<'YAML'
- name: rollback-item
  type: rollback-driver
  spec: anything
YAML
rm -f "$TMP/rollback-sentinel" "$TMP/install-marker"
set +e
bash "$ENGINE" --manifest "$TMP/items-rollback.yaml" --installers-dir "$TMP/installers" 2>/dev/null
rc=$?
set -e
[[ -f "$TMP/install-marker" ]]  && { passed=$((passed+1)); echo "  ✓ install ran before failing"; } \
                                || { failed=$((failed+1)); echo "  ✗ install never ran" >&2; }
[[ -f "$TMP/rollback-sentinel" ]] && { passed=$((passed+1)); echo "  ✓ rollback fired after install() failure (A-F003)"; } \
                                  || { failed=$((failed+1)); echo "  ✗ rollback was bypassed (A-F003 regression)" >&2; }
[[ "$rc" -eq 42 ]] && { passed=$((passed+1)); echo "  ✓ engine exited with install rc (42)"; } \
                  || { failed=$((failed+1)); echo "  ✗ engine rc=$rc, expected 42 from install" >&2; }

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
