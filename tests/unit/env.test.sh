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

# Test 5: DOTFILES_DIR transitional alias
out=$(unset DOTFILES_DIR; MESH_IDENTITY_DIR=/tmp/mid bash -c ". '$WS/scripts/lib/env.sh'; echo \$DOTFILES_DIR")
assert "DOTFILES_DIR aliased to MESH_IDENTITY_DIR" "/tmp/mid" "$out"

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
