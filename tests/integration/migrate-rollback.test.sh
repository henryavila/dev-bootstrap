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

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
