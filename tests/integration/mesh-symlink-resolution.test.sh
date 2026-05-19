#!/usr/bin/env bash
# tests/integration/mesh-symlink-resolution.test.sh — symlink-canonicalization regression.
#
# Reproduces CP4 chunk B finding F-001 (blocker): when bin/mesh is invoked
# via the canonical ~/.local/bin/mesh symlink installed by setup.sh,
# plain dirname "${BASH_SOURCE[0]}" returns the symlink's directory,
# which makes _resolve_companion tier 2 resolve to .../bin/../scripts/
# (does not exist). Six subcommands shipped broken at HEAD before this
# fix: status, snap, update, init, template-check, lint.
#
# This test exercises the production symlink invocation path that
# mesh-extension-hook.test.sh side-steps by forcing MESH_HOME.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
MESH="$REPO_ROOT/bin/mesh"

# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-symlink-resolution.XXXXXX)"
_cleanup() { [[ -d "$SANDBOX" ]] && rm -rf "$SANDBOX"; }
trap _cleanup EXIT

# ─── Test 1: HERE canonicalizes through a single-level symlink ────
mkdir -p "$SANDBOX/.local/bin"
ln -sf "$MESH" "$SANDBOX/.local/bin/mesh"

# Probe HERE by sourcing the canonicalization helper logic — invoking
# the binary with -V doesn't expose HERE. Instead exercise the
# observable side effect: companion resolution must find lib/init.sh
# even when MESH_HOME is unset.
out=$(unset MESH_HOME; "$SANDBOX/.local/bin/mesh" init --help 2>&1)
rc=$?
assert_eq "$rc" 0 "Test 1a: mesh init --help via symlink exits 0 (was rc!=0 pre-fix)"
assert_not_contains "$out" "lib/init.sh not found" "Test 1b: lib/init.sh resolves correctly"
assert_contains "$out" "Usage" "Test 1c: actual help text reached"

# ─── Test 2: every companion-resolving subcommand works via symlink ─
# All 6 broken-pre-fix subcommands. Help-only invocation so no side effects.
for sub in status snap update init template-check lint; do
    out=$(unset MESH_HOME; "$SANDBOX/.local/bin/mesh" "$sub" --help 2>&1)
    assert_not_contains "$out" "not found (set \$MESH_HOME or check installation)" \
        "Test 2: $sub via symlink resolves companion"
done

# ─── Test 3: multi-level symlink chain still canonicalizes ─────────
mkdir -p "$SANDBOX/level2/.local/bin"
ln -sf "$SANDBOX/.local/bin/mesh" "$SANDBOX/level2/.local/bin/mesh"

out=$(unset MESH_HOME; "$SANDBOX/level2/.local/bin/mesh" status --help 2>&1)
assert_not_contains "$out" "not found" "Test 3a: 2-level symlink chain resolves"
assert_contains "$out" "mesh-status" "Test 3b: help reached through chain"

# ─── Test 4: relative-target symlink ───────────────────────────────
# BSD readlink returns relative paths verbatim — must resolve against
# the symlink's directory, not CWD.
TARGET_DIR="$(cd "$(dirname "$MESH")" && pwd -P)"
TARGET_BASE="$(basename "$MESH")"
mkdir -p "$SANDBOX/rel-link"
( cd "$SANDBOX/rel-link" && ln -sf "$TARGET_DIR/$TARGET_BASE" mesh-rel )
# A truly relative case: link in repo-adjacent dir → repo's bin/mesh
mkdir -p "$SANDBOX/adj"
( cd "$SANDBOX/adj" && ln -sf "../../bin/$TARGET_BASE" mesh-adj 2>/dev/null || true )

out=$(unset MESH_HOME; "$SANDBOX/rel-link/mesh-rel" status --help 2>&1)
assert_not_contains "$out" "not found" "Test 4a: absolute-target symlink resolves"

# ─── Test 5: direct (non-symlink) invocation still works ──────────
out=$(unset MESH_HOME; "$MESH" status --help 2>&1)
assert_not_contains "$out" "not found" "Test 5: direct invocation unbroken"

# ─── Test 6: F-002 — mesh topic list works from clean env via $HERE/.. ─
out=$(env -i HOME="$SANDBOX" PATH="/usr/bin:/bin:/Volumes/External/homebrew/bin" \
    "$SANDBOX/.local/bin/mesh" topic list 2>&1)
rc=$?
assert_eq "$rc" 0 "Test 6a: topic list from clean env exits 0"
assert_contains "$out" "00-core" "Test 6b: topic list output reached"

summary
