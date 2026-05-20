#!/usr/bin/env bash
# scripts/migrate-to-engine.sh — Phase 9 bridge migration (spec §7.4).
#
# Migrate this machine to the new 2-layer mesh in one transaction:
# clean-tree gate → atomic lock → pre-snapshot → marker rewrite → branch
# checkout → setup.sh dry-run → setup.sh apply → post-snapshot diff →
# doctor validation. On failure at step 6/7/8/9 the script prints the
# rollback command and exits non-zero without proceeding.
#
# Sandbox knobs (test/dev only — production omits):
#   MESH_STATE_DIR        — override $HOME/.local/state/dev-bootstrap
#   MESH_BRIDGE_REPO_DIR  — override the workstation repo root (default
#                           $HERE/.. per spec §7.4); fixture tests point
#                           this at a temp git repo with main + refactor/
#                           install-engine branches and mock setup.sh +
#                           scripts/runners/doctor.sh so steps 4/6/7/9
#                           run hermetically.
#   MESH_BRIDGE_LIB_ONLY=1 — source-only mode for unit-testing
#                           check_no_removals() in isolation.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
WS_DIR="${MESH_BRIDGE_REPO_DIR:-$HERE/..}"

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

# 0. PRE-FLIGHT — working tree must be clean.
#    git checkout at step 4 would refuse on uncommitted state; abort early
#    here with a named error rather than corrupting mid-migration. Both
#    unstaged and staged changes block.
cd "$WS_DIR"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: $WS_DIR is not a git work tree." >&2
    echo "Set MESH_BRIDGE_REPO_DIR to the workstation checkout, or run $SCRIPT_NAME from within it." >&2
    exit 1
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: working tree at $WS_DIR has uncommitted changes." >&2
    echo "Commit, stash, or discard them before running $SCRIPT_NAME." >&2
    git status --short >&2
    exit 1
fi
echo "[step 0] working tree clean at $WS_DIR"

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
# Snapshot git refs so rollback can restore the pre-migration branch state.
git rev-parse HEAD > "$SNAP_DIR/git-head-before-migration.txt"
git symbolic-ref --short HEAD > "$SNAP_DIR/git-branch-before-migration.txt" 2>/dev/null \
    || echo "(detached)" > "$SNAP_DIR/git-branch-before-migration.txt"
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

# 4. Checkout refactor branch.
git fetch origin refactor/install-engine
git checkout refactor/install-engine
echo "[step 4] checked out refactor/install-engine"

# 5. (removed in spec — was dead code per spec comment)

# 6. Dry-run setup.sh on the post-restructure branch. Refuse to apply
#    anything if the engine cannot project what it would do.
if ! bash setup.sh --dry-run; then
    cat >&2 <<EOF
ERROR: setup.sh --dry-run failed — aborting before any system mutation.
       Repo is on refactor/install-engine; markers are migrated.
       To recover: bash $WS_DIR/scripts/migrate-rollback.sh
EOF
    exit 1
fi
echo "[step 6] setup.sh --dry-run OK"

# 7. Apply.
if ! bash setup.sh; then
    cat >&2 <<EOF
ERROR: setup.sh failed — system may be in a partial state.
       To recover: bash $WS_DIR/scripts/migrate-rollback.sh
EOF
    exit 1
fi
echo "[step 7] setup.sh applied"

# 8. After-snapshot via the same manager probes used in step 2; comm vs
#    the pre-migration list flags any package that disappeared during
#    setup. Engine F-A5 (additive idempotent) guarantees no removal is
#    expected; a non-empty diff means setup performed an unintended
#    uninstall.
snapshot_manager_after() {
    # snapshot_manager_after <name> <probe-command> <list-command...>
    local name="$1"; shift
    local probe="$1"; shift
    # Tool absent post-setup — symmetric with snapshot_manager: leave no file.
    if ! command -v "$probe" >/dev/null 2>&1; then
        return 0
    fi
    if ! "$@" > "$SNAP_DIR/$name.after.txt" 2>/dev/null; then
        printf 'ERROR: after-snapshot for %s failed (tool present but list errored)\n' "$name" >&2
        return 1
    fi
}
snapshot_manager_after brew-formula brew brew list --formula
snapshot_manager_after brew-cask    brew brew list --cask
snapshot_manager_after apt          apt  apt list --installed
snapshot_manager_after npm-global   npm  npm list -g --depth=0
if ! check_no_removals "$SNAP_DIR"; then
    cat >&2 <<EOF
ERROR: package removals detected — aborting.
       To recover: bash $WS_DIR/scripts/migrate-rollback.sh
EOF
    exit 1
fi
echo "[step 8] no package removals — verified"

# 9. Doctor (post-restructure path).
if ! bash scripts/runners/doctor.sh; then
    cat >&2 <<EOF
ERROR: doctor.sh reported a regression — migration left a measurable
       defect on this host. Investigate before declaring success.
       To recover: bash $WS_DIR/scripts/migrate-rollback.sh
EOF
    exit 1
fi
echo "[step 9] doctor.sh OK"

echo ""
echo "==> Migration complete. Validate manually before the next machine."
echo "    Snapshot:        $SNAP_DIR"
echo "    Marker backups:  ~/.{ssh/authorized_keys,bashrc,zshrc,tmux.conf,gitconfig}.mesh-migrate"
