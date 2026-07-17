#!/usr/bin/env bash
# tests/integration/catalog-help.test.sh - catalog command help must be read-only.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
MESH="$REPO_ROOT/bin/mesh"

# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-catalog-help.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

MESH_HOME_FAKE="$SANDBOX/scripts"
IDENTITY_EMPTY="$SANDBOX/identity-empty"
FAKE_CATALOG="$SANDBOX/.catalog"
mkdir -p "$MESH_HOME_FAKE/lib" "$IDENTITY_EMPTY"
ln -s "$REPO_ROOT/scripts/lib/mesh-command.sh" "$MESH_HOME_FAKE/lib/mesh-command.sh"

cat > "$MESH_HOME_FAKE/lib/catalog.sh" <<SH
#!/usr/bin/env bash
mkdir -p "$FAKE_CATALOG"
printf 'GENERATED:%s\n' "\$*"
SH
chmod +x "$MESH_HOME_FAKE/lib/catalog.sh"

run_mesh() {
    MESH_HOME="$MESH_HOME_FAKE" \
    MESH_IDENTITY_DIR="$IDENTITY_EMPTY" \
    "$MESH" "$@"
}

assert_help_is_read_only() {
    local label="$1"
    shift
    rm -rf "$FAKE_CATALOG"

    local out rc
    out="$(run_mesh "$@" 2>&1)"
    rc=$?
    assert_eq "$rc" 0 "$label exits 0"
    assert_contains "$out" "Usage: mesh catalog generate" "$label prints catalog usage"
    assert_not_contains "$out" "GENERATED:" "$label does not run catalog generator"
    if [[ -e "$FAKE_CATALOG" ]]; then
        fail "$label does not write .catalog"
    else
        pass "$label does not write .catalog"
    fi
}

echo "catalog help is read-only"
assert_help_is_read_only "mesh catalog --help" catalog --help
assert_help_is_read_only "mesh catalog -h" catalog -h
assert_help_is_read_only "mesh catalog generate --help" catalog generate --help
assert_help_is_read_only "mesh catalog generate -h" catalog generate -h

echo
echo "catalog generation still delegates"
rm -rf "$FAKE_CATALOG"
out="$(run_mesh catalog generate 2>&1)"
rc=$?
assert_eq "$rc" 0 "mesh catalog generate exits 0"
assert_eq "$out" "GENERATED:" "mesh catalog generate delegates with no extra args"
if [[ -d "$FAKE_CATALOG" ]]; then
    pass "mesh catalog generate writes .catalog"
else
    fail "mesh catalog generate writes .catalog"
fi

echo
summary
