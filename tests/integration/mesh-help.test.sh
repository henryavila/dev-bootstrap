#!/usr/bin/env bash
# tests/integration/mesh-help.test.sh — top-level help dispatch contract.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
MESH="$REPO_ROOT/bin/mesh"

# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-help.XXXXXX)"
_cleanup() { [[ -d "$SANDBOX" ]] && rm -rf "$SANDBOX"; }
trap _cleanup EXIT

IDENTITY_EMPTY="$SANDBOX/identity-empty"
mkdir -p "$IDENTITY_EMPTY"

_mesh_out() {
    MESH_IDENTITY_DIR="$IDENTITY_EMPTY" \
        MESH_HOME="$REPO_ROOT/scripts" \
        "$MESH" "$@" 2>&1
}

echo "Top-level help aliases require the Blink TUI"

out="$(_mesh_out help)"
rc=$?
assert_eq "$rc" 1 "mesh help without a TTY exits 1 instead of pretending to open UI"
assert_contains "$out" "mesh help: needs an interactive terminal" "mesh help routes to the Blink help entrypoint"
assert_not_contains "$out" "Mesh CLI" "mesh help does not print the static usage text"
assert_not_contains "$out" "unknown subcommand" "mesh help is not routed to unknown-subcommand fallback"

out="$(_mesh_out --help)"
rc=$?
assert_eq "$rc" 1 "mesh --help without a TTY exits 1 instead of pretending to open UI"
assert_contains "$out" "mesh help: needs an interactive terminal" "mesh --help routes to the Blink help entrypoint"
assert_not_contains "$out" "Mesh CLI" "mesh --help does not print the static usage text"
assert_not_contains "$out" "unknown subcommand" "mesh --help is not routed to unknown-subcommand fallback"

out="$(_mesh_out -h)"
rc=$?
assert_eq "$rc" 1 "mesh -h without a TTY exits 1 instead of pretending to open UI"
assert_contains "$out" "mesh help: needs an interactive terminal" "mesh -h routes to the Blink help entrypoint"
assert_not_contains "$out" "Mesh CLI" "mesh -h does not print the static usage text"

echo
echo "Unknown subcommands still fail"

out="$(_mesh_out definitely-not-a-command)"
rc=$?
assert_eq "$rc" 1 "unknown top-level subcommand exits 1"
assert_contains "$out" "unknown subcommand" "unknown top-level subcommand prints fallback error"

echo
echo "Extension fallback remains available"

IDENTITY_EXT="$SANDBOX/identity-ext"
mkdir -p "$IDENTITY_EXT/extensions"
cat > "$IDENTITY_EXT/extensions/mesh.sh" <<'EOF'
sub_hello() {
    printf 'hello extension: %s\n' "$*"
}
EOF

out="$(
    MESH_IDENTITY_DIR="$IDENTITY_EXT" \
        MESH_HOME="$REPO_ROOT/scripts" \
        "$MESH" hello world 2>&1
)"
rc=$?
assert_eq "$rc" 0 "extension-defined subcommand exits 0"
assert_contains "$out" "hello extension: world" "extension-defined subcommand still routes through fallback"

summary
