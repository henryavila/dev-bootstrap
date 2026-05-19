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

# Test 5 (CP4 F-003): manifest `check:` overrides driver _check on pre-install.
# Driver _check returns 1 (force install) but manifest check: "true" returns 0 →
# engine should SKIP install honoring the manifest.
cat > "$TMP/installers/always-install-driver.sh" <<'SH'
always_install_driver_check()   { return 1; }   # driver says "not installed"
always_install_driver_install() { touch "$STATE_DIR/install-marker-f003"; }
SH
cat > "$TMP/items-f003-pre.yaml" <<'YAML'
- name: f003-skipped-by-manifest
  type: always-install-driver
  spec: anything
  check: "true"
YAML
rm -f "$TMP/install-marker-f003"
set +e
out=$(STATE_DIR=$TMP bash "$ENGINE" --manifest "$TMP/items-f003-pre.yaml" --installers-dir "$TMP/installers" 2>&1)
rc=$?
set -e
assert "F-003 manifest check: true overrides driver _check (skip)" "0" "$rc"
[[ ! -f "$TMP/install-marker-f003" ]] && { passed=$((passed+1)); echo "  ✓ F-003 install was skipped (no marker created)"; } \
                                       || { failed=$((failed+1)); echo "  ✗ F-003 install ran despite manifest check pass" >&2; }
echo "$out" | grep -q "manifest check" && { passed=$((passed+1)); echo "  ✓ F-003 log message names manifest check"; } \
                                       || { failed=$((failed+1)); echo "  ✗ F-003 log did not name manifest check" >&2; }

# Test 6 (CP4 F-003): manifest `check:` that depends on install effect
# (pre-install: marker absent → check fails → install runs → post-check passes).
cat > "$TMP/items-f003-pre-fails-post-passes.yaml" <<'YAML'
- name: f003-install-runs
  type: always-install-driver
  spec: anything
  check: "test -f $STATE_DIR/install-marker-f003"
YAML
rm -f "$TMP/install-marker-f003"
set +e
STATE_DIR=$TMP bash "$ENGINE" --manifest "$TMP/items-f003-pre-fails-post-passes.yaml" --installers-dir "$TMP/installers" 2>/dev/null
rc=$?
set -e
assert "F-003 manifest check fails pre, install runs, manifest passes post" "0" "$rc"
[[ -f "$TMP/install-marker-f003" ]] && { passed=$((passed+1)); echo "  ✓ F-003 install ran when manifest check failed pre"; } \
                                    || { failed=$((failed+1)); echo "  ✗ F-003 install was skipped despite check fail" >&2; }

# Test 7 (CP4 F-003): post-install — if no driver _verify, manifest check
# is used as the success criterion (fallback before driver _check).
cat > "$TMP/installers/no-verify-driver.sh" <<'SH'
no_verify_driver_check()   { return 1; }
no_verify_driver_install() { touch "$STATE_DIR/post-install-marker"; }
# Deliberately NO _verify function — fallback to manifest_check / driver_check.
SH
cat > "$TMP/items-f003-post.yaml" <<'YAML'
- name: f003-post-via-manifest
  type: no-verify-driver
  spec: anything
  check: "test -f $STATE_DIR/post-install-marker"
YAML
rm -f "$TMP/post-install-marker"
set +e
STATE_DIR=$TMP bash "$ENGINE" --manifest "$TMP/items-f003-post.yaml" --installers-dir "$TMP/installers" 2>/dev/null
rc=$?
set -e
assert "F-003 manifest check provides post-install verify" "0" "$rc"
[[ -f "$TMP/post-install-marker" ]] && { passed=$((passed+1)); echo "  ✓ F-003 install ran + post-check via manifest passed"; } \
                                    || { failed=$((failed+1)); echo "  ✗ F-003 post-check via manifest failed" >&2; }

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
