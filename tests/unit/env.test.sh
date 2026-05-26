#!/usr/bin/env bash
# Unit tests for scripts/lib/env.sh — resolves MESH_WORKSTATION_DIR / MESH_IDENTITY_DIR.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected: $expected, got: $actual)" >&2; fi
}

# Test 1: env.sh resolves MESH_WORKSTATION_DIR from explicit env when set
out=$(MESH_WORKSTATION_DIR=/tmp/mws bash -c ". '$WS/scripts/lib/env.sh'; echo \$MESH_WORKSTATION_DIR")
assert "MESH_WORKSTATION_DIR honored from env" "/tmp/mws" "$out"

# Test 2: falls back to ~/mesh-workstation when unset and ~/.config/mesh/config.env absent
out=$(unset MESH_WORKSTATION_DIR; HOME=/tmp/fakehome-$$ bash -c ". '$WS/scripts/lib/env.sh' 2>/dev/null; echo \$MESH_WORKSTATION_DIR")
assert "MESH_WORKSTATION_DIR fallback" "/tmp/fakehome-$$/mesh-workstation" "$out"

# Test 3: ~/.config/mesh/config.env overrides fallback when present
FAKE=/tmp/fakehome-cfg-$$
mkdir -p "$FAKE/.config/mesh"
echo 'MESH_WORKSTATION_DIR=/custom/path' > "$FAKE/.config/mesh/config.env"
out=$(unset MESH_WORKSTATION_DIR; HOME=$FAKE bash -c ". '$WS/scripts/lib/env.sh'; echo \$MESH_WORKSTATION_DIR")
assert "config.env override applied" "/custom/path" "$out"
rm -rf "$FAKE"

# Test 4: MESH_IDENTITY_DIR same pattern
out=$(MESH_IDENTITY_DIR=/tmp/mid bash -c ". '$WS/scripts/lib/env.sh'; echo \$MESH_IDENTITY_DIR")
assert "MESH_IDENTITY_DIR honored from env" "/tmp/mid" "$out"

# Test 5: pre-set MESH_WORKSTATION_DIR is NOT overwritten by config.env when MESH_IDENTITY_DIR is also unset (i.e., both must be unset before config.env loads)
FAKE6=/tmp/fakehome-cfg-mixed-$$
mkdir -p "$FAKE6/.config/mesh"
cat > "$FAKE6/.config/mesh/config.env" <<EOF
MESH_WORKSTATION_DIR=/from-config
MESH_IDENTITY_DIR=/from-config-id
EOF
out=$(unset MESH_IDENTITY_DIR; MESH_WORKSTATION_DIR=/preset HOME=$FAKE6 bash -c ". '$WS/scripts/lib/env.sh'; echo \$MESH_WORKSTATION_DIR")
assert "pre-set workstation NOT overwritten by config.env when identity is unset" "/preset" "$out"
rm -rf "$FAKE6"

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
