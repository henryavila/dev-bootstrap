#!/usr/bin/env bash
# Integration test for rollback: simulate marker mutation + git checkout + lock; assert restoration.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
ROLLBACK="$WS/scripts/migrate-rollback.sh"

passed=0; failed=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Build a fake $HOME with markers + snapshot + lock
FAKE=$TMP/home
mkdir -p "$FAKE/.local/state/dev-bootstrap/snapshots/$(hostname)-pre-migration"
SNAP="$FAKE/.local/state/dev-bootstrap/snapshots/$(hostname)-pre-migration"

# Pre-migration original + mutation
echo "ORIGINAL CONTENT" > "$FAKE/.bashrc.mesh-migrate"
echo "MUTATED CONTENT" > "$FAKE/.bashrc"

# Build a fake repo to test git restore
mkdir -p "$FAKE/repo"
(
    cd "$FAKE/repo"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    touch f
    git add f
    git commit -q -m "init"
    # Ensure we are on main (default branch may already be named main)
    git checkout -q -B main
    git checkout -q -b refactor/install-engine
)
prev_sha=$(cd "$FAKE/repo" && git rev-parse HEAD)
echo "main" > "$SNAP/git-branch-before-migration.txt"
echo "$prev_sha" > "$SNAP/git-head-before-migration.txt"

# Lock file
touch "$FAKE/.local/state/dev-bootstrap/migration.lock"

# Run rollback with fake HOME and fake repo CWD (rollback cd's to $HERE/..)
# We invoke via bash + custom HERE simulation: place rollback in $FAKE/repo/scripts/
mkdir -p "$FAKE/repo/scripts"
cp "$ROLLBACK" "$FAKE/repo/scripts/migrate-rollback.sh"
chmod +x "$FAKE/repo/scripts/migrate-rollback.sh"

HOME=$FAKE bash "$FAKE/repo/scripts/migrate-rollback.sh" >/dev/null 2>&1 || true

# Assertions
got=$(cat "$FAKE/.bashrc")
if [[ "$got" == "ORIGINAL CONTENT" ]]; then passed=$((passed+1)); echo "  ✓ marker file restored from .mesh-migrate"
else failed=$((failed+1)); echo "  ✗ marker file restore (got: $got)" >&2; fi

cur_branch=$(cd "$FAKE/repo" && git rev-parse --abbrev-ref HEAD)
if [[ "$cur_branch" == "main" ]]; then passed=$((passed+1)); echo "  ✓ git branch restored to main"
else failed=$((failed+1)); echo "  ✗ git branch restore (got: $cur_branch)" >&2; fi

if [[ ! -f "$FAKE/.local/state/dev-bootstrap/migration.lock" ]]; then passed=$((passed+1)); echo "  ✓ lock released"
else failed=$((failed+1)); echo "  ✗ lock still present" >&2; fi

# Bonus: backup file removed after restore
if [[ ! -f "$FAKE/.bashrc.mesh-migrate" ]]; then passed=$((passed+1)); echo "  ✓ backup .mesh-migrate removed"
else failed=$((failed+1)); echo "  ✗ backup file still present" >&2; fi

# --- CP4 A3 F-003: rollback preflight when git metadata is missing ---
# Build a SECOND fixture where snapshot dir exists but git-branch /
# git-head files do NOT (matches the v0 bridge's actual state today).
# Assert rollback exits 2 WITHOUT mutating markers and WITHOUT removing the lock.
FAKE2=$TMP/home2
mkdir -p "$FAKE2/.local/state/dev-bootstrap/snapshots/$(hostname)-pre-migration"
# Pre-migration backup + post-mutation content (rollback must NOT touch these)
echo "PRE-PRESERVE" > "$FAKE2/.bashrc.mesh-migrate"
echo "POST-MUTATION" > "$FAKE2/.bashrc"
# Lock that rollback must NOT delete when preflight aborts
touch "$FAKE2/.local/state/dev-bootstrap/migration.lock"
# Re-use the in-place rollback at $FAKE/repo/scripts/ (cwd-independent)
# `|| true` keeps the test alive under set -e — we expect rc=2 by design.
preflight_rc=0
HOME=$FAKE2 bash "$FAKE/repo/scripts/migrate-rollback.sh" > /tmp/rollback-preflight.out 2>&1 || preflight_rc=$?

if [[ $preflight_rc -eq 2 ]]; then passed=$((passed+1)); echo "  ✓ F-003: rollback exits 2 on missing git metadata"
else failed=$((failed+1)); echo "  ✗ F-003: rollback exits 2 on missing git metadata (got rc=$preflight_rc)" >&2; fi

if grep -q "rollback aborted" /tmp/rollback-preflight.out; then
    passed=$((passed+1)); echo "  ✓ F-003: error message identifies 'rollback aborted'"
else
    failed=$((failed+1)); echo "  ✗ F-003: error message identifies 'rollback aborted'" >&2
fi

# Critical: .mesh-migrate backup MUST be preserved (audit trail)
if [[ -f "$FAKE2/.bashrc.mesh-migrate" ]] && \
   [[ "$(cat "$FAKE2/.bashrc.mesh-migrate")" == "PRE-PRESERVE" ]]; then
    passed=$((passed+1)); echo "  ✓ F-003: .mesh-migrate backup preserved when preflight fails"
else
    failed=$((failed+1)); echo "  ✗ F-003: .mesh-migrate backup destroyed by preflight failure" >&2
fi

# Markers MUST NOT be restored to pre-migration content when preflight fails
if [[ "$(cat "$FAKE2/.bashrc")" == "POST-MUTATION" ]]; then
    passed=$((passed+1)); echo "  ✓ F-003: marker file untouched on preflight fail"
else
    failed=$((failed+1)); echo "  ✗ F-003: marker file mutated despite preflight fail" >&2
fi

# Lock must NOT be removed (no partial cleanup)
if [[ -f "$FAKE2/.local/state/dev-bootstrap/migration.lock" ]]; then
    passed=$((passed+1)); echo "  ✓ F-003: lock preserved on preflight fail"
else
    failed=$((failed+1)); echo "  ✗ F-003: lock removed despite preflight fail" >&2
fi
rm -f /tmp/rollback-preflight.out

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
