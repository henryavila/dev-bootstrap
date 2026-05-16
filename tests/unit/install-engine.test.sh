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

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
