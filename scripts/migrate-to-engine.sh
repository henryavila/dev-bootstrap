#!/usr/bin/env bash
# bridge-v0.sh — P2 prototype of scripts/migrate-to-engine.sh from spec §7.4.
#
# Validates the bridge ARCHITECTURE (steps 0-3 + 8 abort logic), not the
# end-to-end migration (steps 4-7 need setup.sh and a real refactor branch).
#
# Differences from spec §7.4 pseudocode:
#   - Step 4 (git checkout refactor/install-engine) is SKIPPED with a warning.
#   - Step 6/7 (setup.sh --dry-run + apply) replaced by a MOCK that always passes.
#   - State path uses $MESH_STATE_DIR (default $HOME/.local/state/dev-bootstrap)
#     so a sandboxed HOME isolates all mutations to a fixture directory.
#
# Pass criterion (handoff §G4 P2):
#   - Executes without leaving fixture in inconsistent state.
#   - Step 3 marker rename is case-insensitive (catches bug-2026-04-23 pattern).
#   - Step 8 abort-on-removal logic works (simulated).

set -euo pipefail

# CP4 chunk A3 findings F-001 (blocker) + F-002 (critical) — fail-closed gate.
# The body of this script is the Phase 2 P2 prototype (header above): steps
# 4/6/7/9 SKIP/MOCK any real migration, and step 8 synthesizes the post-
# migration package snapshot from the pre-migration snapshot (so "no
# removals verified" is true by construction, not by check). Running this
# on a real workstation rewrites marker files but does NOT migrate the
# install layout, and reports success regardless.
#
# Tests + sandbox runs set MESH_BRIDGE_V0_OK=1 to acknowledge v0 semantics.
# Phase 9 users hit the gate and must use the per-machine runbook OR
# wait for the real §7.4 bridge to be written.
if [ "${MESH_BRIDGE_V0_OK:-0}" != "1" ] && [ "${MESH_BRIDGE_LIB_ONLY:-0}" != "1" ]; then
    cat <<'GATE' >&2
ERROR: scripts/migrate-to-engine.sh is the v0 prototype — not the
       production Phase 9 bridge.

       The current implementation:
         - SKIPS git checkout of the refactor branch (step 4)
         - MOCKS setup.sh --dry-run (step 6) and SKIPS real apply (step 7)
         - SYNTHESIZES the post-migration package snapshot from the
           pre-migration snapshot (step 8) — so "no removals verified"
           is true by construction, not by check
         - SKIPS doctor.sh validation (step 9)

       Running this on a real workstation will rewrite marker files but
       will NOT migrate the install layout, and will report success
       regardless.

       For Phase 9, use the per-machine migration runbook at
       docs/onboard-new-machine.md until the real §7.4 bridge is written.

       For sandbox/test invocation, set MESH_BRIDGE_V0_OK=1 to ack v0.

       See CP4 A3 findings F-001 + F-002 in the review file:
       dotfiles/.atomic-skills/reviews/2026-05-19-CP4-mesh-restructure.md
GATE
    exit 2
fi

MESH_STATE_DIR="${MESH_STATE_DIR:-$HOME/.local/state/dev-bootstrap}"

# H5 fix: step 8 logic exposed as function so tests can exercise the abort
# path directly with controlled snapshot fixtures.
#
# H-2 fix (checkpoint-2): iterate over all 4 managers, not just brew-formula;
# require BOTH before/after files to exist when before exists (avoid silent pass
# when after-snapshot wasn't captured). Tools that never produced a before-snapshot
# (because the tool isn't installed on this host) are skipped silently.
MESH_BRIDGE_MANAGERS="brew-formula brew-cask apt npm-global"

check_no_removals() {
    local snap_dir="$1"
    local mgr before after removals rc=0
    for mgr in $MESH_BRIDGE_MANAGERS; do
        before="$snap_dir/$mgr.txt"
        after="$snap_dir/$mgr.after.txt"
        # Manager not in use on this host (no before-snapshot taken) → skip.
        if [ ! -f "$before" ] && [ ! -f "$after" ]; then
            continue
        fi
        # Before exists but after missing → after-snapshot wasn't captured.
        # Refuse to declare safe (would be a silent pass otherwise).
        if [ -f "$before" ] && [ ! -f "$after" ]; then
            printf 'ERROR: %s after-snapshot missing — refusing to declare safe\n' "$mgr" >&2
            rc=1
            continue
        fi
        # After exists but before missing → tool installed during migration,
        # not a removal → ok.
        if [ ! -f "$before" ] && [ -f "$after" ]; then
            continue
        fi
        # Both present → run comm.
        removals=$(comm -23 <(sort "$before") <(sort "$after"))
        if [ -n "$removals" ]; then
            printf 'ERROR: %s packages removed:\n%s\n' "$mgr" "$removals" >&2
            rc=1
        fi
    done
    return $rc
}

# Test mode: if MESH_BRIDGE_LIB_ONLY=1, source-only (don't run steps).
[ "${MESH_BRIDGE_LIB_ONLY:-0}" = "1" ] && return 0 2>/dev/null || true

# 0. PRE-FLIGHT — skip git check in v0 (no repo in fixture). Real bridge checks
#    `git diff --quiet` on the workstation repo.
echo "[step 0] pre-flight: SKIP (v0 has no repo; spec checks working tree clean)"

# 1. Lock-file — ATOMIC acquisition via noclobber (O_EXCL).
#    CX-H1 fix (checkpoint-3): the previous `[ -f $LOCK ] && touch $LOCK`
#    pattern was check-then-touch, NOT atomic. Two concurrent bridge runs
#    could both pass the `-f` check before either created the file.
#    `( set -C; : > "$LOCK" )` opens with O_EXCL — kernel-level atomic;
#    if the lock already exists, the redirection fails and we exit 1.
#    The subshell scopes `set -C` so it doesn't leak; the file persists
#    after the subshell, so the parent's EXIT trap cleans it up normally.
LOCK="$MESH_STATE_DIR/migration.lock"
mkdir -p "$(dirname "$LOCK")"
if ! ( set -C; : > "$LOCK" ) 2>/dev/null; then
    echo "ERROR: lock exists at $LOCK — previous run incomplete or another migration is in progress." >&2
    exit 1
fi
trap 'rm -f "$LOCK"' EXIT
# Record holder metadata for forensics after acquisition succeeded.
printf 'pid=%s\nhost=%s\nstarted=%s\n' "$$" "$(hostname)" "$(date -u +%FT%TZ)" > "$LOCK"
echo "[step 1] lock acquired: $LOCK"

# 2. Snapshot pre-migration.
# H-2 fix (checkpoint-2): only create snapshot file when the tool is actually
# present. Empty files from absent tools used to make step 8's comm a vacuous
# no-op (would silently approve any migration on hosts without brew/apt/npm).
SNAP_DIR="$MESH_STATE_DIR/snapshots/$(hostname)-pre-migration"
mkdir -p "$SNAP_DIR"
snapshot_manager() {
    # snapshot_manager <name> <probe-command> <list-command...>
    local name="$1"; shift
    local probe="$1"; shift
    if ! command -v "$probe" >/dev/null 2>&1; then
        # Tool absent: leave NO file (distinguishes "absent" from "present but empty").
        return 0
    fi
    if ! "$@" > "$SNAP_DIR/$name.txt" 2>/dev/null; then
        # Tool present but failed (e.g., brew lock contention) — abort.
        printf 'ERROR: snapshot for %s failed (tool present but list errored)\n' "$name" >&2
        return 1
    fi
}
snapshot_manager brew-formula brew brew list --formula
snapshot_manager brew-cask    brew brew list --cask
snapshot_manager apt          apt  apt list --installed
snapshot_manager npm-global   npm  npm list -g --depth=0
echo "[step 2] snapshot taken at $SNAP_DIR"
echo "         files: $(ls "$SNAP_DIR" 2>/dev/null | tr '\n' ' ')"

# 3. Markers rename CASE-INSENSITIVE (per L16 / bug-2026-04-23)
echo "[step 3] marker rename (case-insensitive)"
renamed_count=0
for f in "$HOME/.ssh/authorized_keys" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.tmux.conf" "$HOME/.gitconfig"; do
    [ -f "$f" ] || continue
    # C-1 fix (checkpoint-2): guard backup creation. Re-running the bridge
    # without this guard would copy the ALREADY-MIGRATED file over the backup,
    # destroying the rollback audit trail. .mesh-migrate is now a one-shot
    # snapshot of pre-migration content.
    [ -f "$f.mesh-migrate" ] || cp "$f" "$f.mesh-migrate"
    python3 - "$f" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()
new = re.sub(r'dotfiles-managed:', 'mesh-managed:', text, flags=re.IGNORECASE)
new = re.sub(r'managed by dev-bootstrap', 'managed by mesh-workstation', new, flags=re.IGNORECASE)
p.write_text(new)
PY
    if ! diff -q "$f" "$f.mesh-migrate" >/dev/null 2>&1; then
        renamed_count=$((renamed_count + 1))
        echo "         modified: $f"
    fi
done
echo "         files with marker rewrites: $renamed_count"

# 4. SKIP — git checkout refactor branch (v0 fixture has no repo)
echo "[step 4] git checkout: SKIP (v0)"

# 5. (removed in spec — was dead code per spec comment)

# 6. Dry-run MOCK — pretend setup.sh --dry-run succeeds
echo "[step 6] setup.sh --dry-run: MOCK"
echo "         [mock] would install: foo, bar, baz"
echo "         [mock] would skip: existing-pkg"
echo "         [mock] dry-run OK"

# 7. SKIP — real apply (no setup.sh in v0)
echo "[step 7] setup.sh apply: SKIP (v0)"

# 8. Verify packages diff (no removals expected).
#    Synthesize after-snapshot identical to before for each manager that
#    produced a before-snapshot. H-2 fix: only manage files that exist
#    (no longer relying on empty stubs).
for mgr in $MESH_BRIDGE_MANAGERS; do
    if [ -f "$SNAP_DIR/$mgr.txt" ]; then
        cp "$SNAP_DIR/$mgr.txt" "$SNAP_DIR/$mgr.after.txt"
    fi
done
check_no_removals "$SNAP_DIR" || exit 1
echo "[step 8] no package removals — verified"

# 9. SKIP — doctor.sh
echo "[step 9] doctor.sh: SKIP (v0)"

echo ""
echo "==> v0 bridge completed without corruption. Snapshot: $SNAP_DIR"
