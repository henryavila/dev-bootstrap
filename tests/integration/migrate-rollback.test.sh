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
mkdir -p "$FAKE/.local/state/mesh/snapshots/$(hostname)-pre-migration"
SNAP="$FAKE/.local/state/mesh/snapshots/$(hostname)-pre-migration"

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
touch "$FAKE/.local/state/mesh/migration.lock"

# Run rollback with fake HOME and fake repo CWD (rollback cd's to $HERE/..)
# We invoke via bash + custom HERE simulation: place rollback in $FAKE/repo/scripts/
mkdir -p "$FAKE/repo/scripts/lib"
cp "$ROLLBACK" "$FAKE/repo/scripts/migrate-rollback.sh"
chmod +x "$FAKE/repo/scripts/migrate-rollback.sh"
# rollback sources scripts/lib/state-dir.sh (T-004); provide it in the fake repo.
cp "$WS/scripts/lib/state-dir.sh" "$FAKE/repo/scripts/lib/state-dir.sh"

HOME=$FAKE bash "$FAKE/repo/scripts/migrate-rollback.sh" >/dev/null 2>&1 || true

# Assertions
got=$(cat "$FAKE/.bashrc")
if [[ "$got" == "ORIGINAL CONTENT" ]]; then passed=$((passed+1)); echo "  ✓ marker file restored from .mesh-migrate"
else failed=$((failed+1)); echo "  ✗ marker file restore (got: $got)" >&2; fi

cur_branch=$(cd "$FAKE/repo" && git rev-parse --abbrev-ref HEAD)
if [[ "$cur_branch" == "main" ]]; then passed=$((passed+1)); echo "  ✓ git branch restored to main"
else failed=$((failed+1)); echo "  ✗ git branch restore (got: $cur_branch)" >&2; fi

if [[ ! -f "$FAKE/.local/state/mesh/migration.lock" ]]; then passed=$((passed+1)); echo "  ✓ lock released"
else failed=$((failed+1)); echo "  ✗ lock still present" >&2; fi

# Bonus: backup file removed after restore
if [[ ! -f "$FAKE/.bashrc.mesh-migrate" ]]; then passed=$((passed+1)); echo "  ✓ backup .mesh-migrate removed"
else failed=$((failed+1)); echo "  ✗ backup file still present" >&2; fi

# --- CP4 A3 F-003: rollback preflight when git metadata is missing ---
# Build a SECOND fixture where snapshot dir exists but git-branch /
# git-head files do NOT (matches the v0 bridge's actual state today).
# Assert rollback exits 2 WITHOUT mutating markers and WITHOUT removing the lock.
FAKE2=$TMP/home2
mkdir -p "$FAKE2/.local/state/mesh/snapshots/$(hostname)-pre-migration"
# Pre-migration backup + post-mutation content (rollback must NOT touch these)
echo "PRE-PRESERVE" > "$FAKE2/.bashrc.mesh-migrate"
echo "POST-MUTATION" > "$FAKE2/.bashrc"
# Lock that rollback must NOT delete when preflight aborts
touch "$FAKE2/.local/state/mesh/migration.lock"
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
if [[ -f "$FAKE2/.local/state/mesh/migration.lock" ]]; then
    passed=$((passed+1)); echo "  ✓ F-003: lock preserved on preflight fail"
else
    failed=$((failed+1)); echo "  ✗ F-003: lock removed despite preflight fail" >&2
fi
rm -f /tmp/rollback-preflight.out

# --- CP4 A3-F-005: lock-aware rollback ---
# Bridge step 1 writes pid=$$\nhost=$(hostname)\nstarted=... to the lock
# file. Rollback must inspect it before deletion: refuse when the lock
# claims an active bridge on this host, accept the override via
# --force-stale-lock, and treat any other state (dead pid, different
# host, no metadata) as stale and clean it up.

# Helper: build a fresh fixture with marker backup + snapshot metadata
# so the preflight passes and we exercise the lock branch only.
fixture_with_metadata() {
    local fake="$1"
    mkdir -p "$fake/.local/state/mesh/snapshots/$(hostname)-pre-migration"
    local snap="$fake/.local/state/mesh/snapshots/$(hostname)-pre-migration"
    echo "ORIGINAL" > "$fake/.bashrc.mesh-migrate"
    echo "MUTATED"  > "$fake/.bashrc"
    echo "main" > "$snap/git-branch-before-migration.txt"
    # Use the head of the already-built $FAKE/repo (any valid SHA works).
    git -C "$FAKE/repo" rev-parse HEAD > "$snap/git-head-before-migration.txt"
}

# Scenario A: lock claims THIS host but pid is dead → treated as stale.
FAKE_DEADPID=$TMP/home-deadpid
fixture_with_metadata "$FAKE_DEADPID"
# pid 1 on a developer machine is launchd (mac) / systemd (linux), which
# *is* alive. Use a guaranteed-dead pid by spawning a true that exits.
( true ) &
dead_pid=$!
wait $dead_pid
printf 'pid=%s\nhost=%s\nstarted=2026-05-20T00:00:00Z\n' "$dead_pid" "$(hostname)" \
    > "$FAKE_DEADPID/.local/state/mesh/migration.lock"
HOME=$FAKE_DEADPID bash "$FAKE/repo/scripts/migrate-rollback.sh" > /tmp/rollback-deadpid.out 2>&1
deadpid_rc=$?
if [[ $deadpid_rc -eq 0 ]] && [[ ! -f "$FAKE_DEADPID/.local/state/mesh/migration.lock" ]]; then
    passed=$((passed+1)); echo "  ✓ F-005: dead pid → lock cleared, rollback succeeds"
else
    failed=$((failed+1)); echo "  ✗ F-005: dead pid scenario (rc=$deadpid_rc, lock present=$([ -f "$FAKE_DEADPID/.local/state/mesh/migration.lock" ] && echo yes || echo no))" >&2
fi
if grep -q 'stale lock' /tmp/rollback-deadpid.out; then
    passed=$((passed+1)); echo "  ✓ F-005: dead pid scenario emits 'stale lock' explanation"
else
    failed=$((failed+1)); echo "  ✗ F-005: dead pid scenario missing 'stale lock' message" >&2
fi

# Scenario B: lock claims a DIFFERENT host → treated as stale regardless of pid.
FAKE_OTHERHOST=$TMP/home-otherhost
fixture_with_metadata "$FAKE_OTHERHOST"
printf 'pid=1\nhost=not-this-host-%s\nstarted=2026-05-20T00:00:00Z\n' "$$" \
    > "$FAKE_OTHERHOST/.local/state/mesh/migration.lock"
HOME=$FAKE_OTHERHOST bash "$FAKE/repo/scripts/migrate-rollback.sh" > /tmp/rollback-otherhost.out 2>&1
otherhost_rc=$?
if [[ $otherhost_rc -eq 0 ]] && [[ ! -f "$FAKE_OTHERHOST/.local/state/mesh/migration.lock" ]]; then
    passed=$((passed+1)); echo "  ✓ F-005: different host → lock cleared"
else
    failed=$((failed+1)); echo "  ✗ F-005: different-host scenario (rc=$otherhost_rc)" >&2
fi

# Scenario C: lock claims THIS host and pid IS alive → refuse without --force.
FAKE_ACTIVE=$TMP/home-active
fixture_with_metadata "$FAKE_ACTIVE"
# Use OUR shell's pid as the "active" pid — kill -0 $$ is guaranteed alive.
printf 'pid=%s\nhost=%s\nstarted=2026-05-20T00:00:00Z\n' "$$" "$(hostname)" \
    > "$FAKE_ACTIVE/.local/state/mesh/migration.lock"
active_rc=0
HOME=$FAKE_ACTIVE bash "$FAKE/repo/scripts/migrate-rollback.sh" > /tmp/rollback-active.out 2>&1 || active_rc=$?
if [[ $active_rc -eq 2 ]] && [[ -f "$FAKE_ACTIVE/.local/state/mesh/migration.lock" ]]; then
    passed=$((passed+1)); echo "  ✓ F-005: active pid → rollback exits 2, lock preserved"
else
    failed=$((failed+1)); echo "  ✗ F-005: active-pid scenario (rc=$active_rc, lock present=$([ -f "$FAKE_ACTIVE/.local/state/mesh/migration.lock" ] && echo yes || echo no))" >&2
fi
if grep -q 'force-stale-lock' /tmp/rollback-active.out; then
    passed=$((passed+1)); echo "  ✓ F-005: active-pid error names --force-stale-lock flag"
else
    failed=$((failed+1)); echo "  ✗ F-005: active-pid error missing --force-stale-lock hint" >&2
fi

# Scenario D: same lock + --force-stale-lock → delete + succeed.
HOME=$FAKE_ACTIVE bash "$FAKE/repo/scripts/migrate-rollback.sh" --force-stale-lock \
    > /tmp/rollback-force.out 2>&1
force_rc=$?
if [[ $force_rc -eq 0 ]] && [[ ! -f "$FAKE_ACTIVE/.local/state/mesh/migration.lock" ]]; then
    passed=$((passed+1)); echo "  ✓ F-005: --force-stale-lock overrides active-pid refusal"
else
    failed=$((failed+1)); echo "  ✗ F-005: --force-stale-lock did not release lock (rc=$force_rc)" >&2
fi

rm -f /tmp/rollback-deadpid.out /tmp/rollback-otherhost.out \
      /tmp/rollback-active.out /tmp/rollback-force.out

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
