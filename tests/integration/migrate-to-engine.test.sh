#!/usr/bin/env bash
# Integration test for scripts/migrate-to-engine.sh — Phase 9 bridge.
#
# Validation:
#   - Sandboxed HOME + MESH_STATE_DIR isolate marker/lock/snapshot mutations
#   - MESH_BRIDGE_REPO_DIR points the bridge at a fixture git repo with
#     main + refactor/install-engine branches + bare-repo origin so step 0
#     (clean-tree check) and step 4 (git fetch + checkout) run hermetically
#   - All existing v0 assertions (lock, snapshot, marker rewrite, removal
#     abort, atomic lock acquisition) still hold against the same bridge

# C1 fix: enable pipefail so `bash $BRIDGE | sed` propagates bridge's exit code.
set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
BRIDGE="$WS/scripts/migrate-to-engine.sh"
FIX="/tmp/mesh-p2-fixture"

pass=0
fail=0
fails=""

assert() {
    local label="$1"; shift
    if eval "$@"; then
        pass=$((pass+1))
        echo "  PASS: $label"
    else
        fail=$((fail+1))
        fails="$fails\n    FAIL: $label   (cond: $*)"
        echo "  FAIL: $label   (cond: $*)"
    fi
}

# Build a minimal fixture workstation git repo at $1 with main + refactor/
# install-engine branches and a bare-repo origin one level up. The refactor
# branch ships mock setup.sh + scripts/runners/doctor.sh that read MOCK_*_RC
# env vars from the bridge's parent process — that's how the test drives
# setup.sh dry-run / apply / doctor success-and-failure modes without
# touching the real workstation tooling.
#
# Both mocks tee a trace line into $HOME so tests can verify each step ran.
setup_fake_ws_repo() {
    local ws="$1"
    local bare="$ws.origin.bare"
    rm -rf "$ws" "$bare"
    mkdir -p "$ws"
    git init --bare -q "$bare"
    (
        cd "$ws"
        git init -q -b main
        git config user.email "t@example.com"
        git config user.name "fixture"
        git config commit.gpgsign false
        echo "# fake workstation" > README
        git add README
        git commit -q -m "init main"
        git checkout -q -b refactor/install-engine
        echo "refactor-branch-marker" > .ref-marker
        cat > setup.sh <<'MOCK'
#!/usr/bin/env bash
# mock setup.sh — driven by MOCK_SETUP_DRYRUN_RC + MOCK_SETUP_APPLY_RC.
mode=apply
case "${1:-}" in
    --dry-run) mode=dryrun ;;
esac
printf 'setup.sh: mode=%s args=%s\n' "$mode" "$*" >> "${HOME:-/tmp}/.mock-setup-trace"
if [ "$mode" = "dryrun" ]; then
    exit "${MOCK_SETUP_DRYRUN_RC:-0}"
fi
exit "${MOCK_SETUP_APPLY_RC:-0}"
MOCK
        mkdir -p scripts/runners
        cat > scripts/runners/doctor.sh <<'MOCK'
#!/usr/bin/env bash
# mock doctor.sh — driven by MOCK_DOCTOR_RC.
printf 'doctor.sh: args=%s\n' "$*" >> "${HOME:-/tmp}/.mock-doctor-trace"
exit "${MOCK_DOCTOR_RC:-0}"
MOCK
        chmod +x setup.sh scripts/runners/doctor.sh
        git add .ref-marker setup.sh scripts/runners/doctor.sh
        git commit -q -m "refactor: mock setup.sh + doctor.sh"
        git checkout -q main
        git remote add origin "$bare"
        git push -q origin main refactor/install-engine
    )
}

rm -rf "$FIX"
mkdir -p "$FIX/home"
setup_fake_ws_repo "$FIX/ws-fake"
MAIN_PREV_SHA=$(git -C "$FIX/ws-fake" rev-parse HEAD)

# Fixture marker files — mixing case, both managed-by and dotfiles-managed:
cat > "$FIX/home/.bashrc" <<'EOF'
# dotfiles-managed: 30-shell start
export PS1='\u@\h:\w\$ '
# dotfiles-managed: 30-shell end
EOF
cat > "$FIX/home/.zshrc" <<'EOF'
# Managed by dev-bootstrap (case-mixed: M capital from bug-2026-04-23)
alias ll='ls -la'
# Managed by dev-bootstrap end
EOF
cat > "$FIX/home/.tmux.conf" <<'EOF'
# DOTFILES-MANAGED: 40-tmux start (UPPERCASE — extreme case-mixing)
set -g mouse on
# DOTFILES-MANAGED: 40-tmux end
EOF
cat > "$FIX/home/.gitconfig" <<'EOF'
[user]
    email = test@example.com
# No managed markers in this file — should NOT be touched.
EOF

# H4 fix: removed the "external-canary" tautology (counted files nothing creates).
# Real sandbox proof = mtime snapshot of real $HOME's fingerprint vs after.
REAL_HOME_MTIME=$(stat -f '%m' "$HOME" 2>/dev/null || stat -c '%Y' "$HOME" 2>/dev/null || echo 0)

# Run bridge with sandboxed HOME (pipefail above ensures bridge's rc propagates).
# CP4 A3 F-001: explicit acks the v0 prototype gate.
echo ""
echo "=== Running bridge with HOME=$FIX/home + WS=$FIX/ws-fake ==="
MESH_BRIDGE_REPO_DIR="$FIX/ws-fake" \
    HOME="$FIX/home" MESH_STATE_DIR="$FIX/home/.local/state/dev-bootstrap" \
    bash "$BRIDGE" 2>&1 | sed 's/^/  /'
rc=${PIPESTATUS[0]}

echo ""
echo "=== Assertions ==="
assert "bridge exited 0" "[ $rc -eq 0 ]"

# Step 1: lock file should be released on EXIT trap
assert "lock file released after exit" \
    "[ ! -f '$FIX/home/.local/state/dev-bootstrap/migration.lock' ]"

# Step 2: snapshot dir exists
SNAP="$FIX/home/.local/state/dev-bootstrap/snapshots/$(hostname)-pre-migration"
assert "snapshot directory created" "[ -d '$SNAP' ]"
assert "snapshot has brew-formula.txt" "[ -f '$SNAP/brew-formula.txt' ]"
# CX-M2 (checkpoint-3): brew-cask is the second brew snapshot — was claimed
# in RESULT but never asserted. brew is present on this Mac dev host so the
# file must exist; on hosts without brew, the bridge correctly omits both.
assert "snapshot has brew-cask.txt (brew present)" "[ -f '$SNAP/brew-cask.txt' ]"

# Step 3: markers renamed (case-insensitive)
assert ".bashrc lowercase markers rewritten" \
    "! grep -q 'dotfiles-managed:' '$FIX/home/.bashrc' && grep -q 'mesh-managed:' '$FIX/home/.bashrc'"
assert ".zshrc CASE-MIXED 'Managed by dev-bootstrap' rewritten" \
    "! grep -qi 'managed by dev-bootstrap' '$FIX/home/.zshrc' && grep -qi 'managed by mesh-workstation' '$FIX/home/.zshrc'"
assert ".tmux.conf UPPERCASE markers rewritten" \
    "! grep -qi 'dotfiles-managed:' '$FIX/home/.tmux.conf' && grep -qi 'mesh-managed:' '$FIX/home/.tmux.conf'"
assert ".gitconfig untouched (no markers)" \
    "! grep -qi 'mesh' '$FIX/home/.gitconfig'"

# Step 3: backups exist with PRE-rename content
assert ".bashrc.mesh-migrate backup exists" "[ -f '$FIX/home/.bashrc.mesh-migrate' ]"
assert ".bashrc backup preserves pre-rename content" \
    "grep -q 'dotfiles-managed:' '$FIX/home/.bashrc.mesh-migrate'"

# H4 fix: real sandbox proof — REAL $HOME mtime fingerprint unchanged.
REAL_HOME_MTIME_AFTER=$(stat -f '%m' "$HOME" 2>/dev/null || stat -c '%Y' "$HOME" 2>/dev/null || echo 0)
assert "real \$HOME directory mtime unchanged (sandbox redirect honored)" \
    "[ '$REAL_HOME_MTIME' = '$REAL_HOME_MTIME_AFTER' ]"

# Step 2 (git ref snapshot): pre-migration HEAD + branch captured for rollback.
assert "snapshot has git-head-before-migration.txt" \
    "[ -f '$SNAP/git-head-before-migration.txt' ]"
assert "git-head-before-migration.txt records pre-migration main SHA" \
    "[ \"\$(cat '$SNAP/git-head-before-migration.txt')\" = '$MAIN_PREV_SHA' ]"
assert "git-branch-before-migration.txt records 'main'" \
    "[ \"\$(cat '$SNAP/git-branch-before-migration.txt')\" = 'main' ]"

# Step 4: real branch checkout — fixture repo is now on refactor/install-engine.
assert "fixture repo HEAD is now refactor/install-engine" \
    "[ \"\$(git -C '$FIX/ws-fake' rev-parse --abbrev-ref HEAD)\" = 'refactor/install-engine' ]"
assert "fixture repo has the .ref-marker from refactor branch" \
    "[ -f '$FIX/ws-fake/.ref-marker' ]"

# --- Step 0 negative: dirty working tree aborts before lock acquired ---
echo ""
echo "=== Step 0: dirty working tree aborts cleanly ==="
FIX_DIRTY="/tmp/mesh-p2-fixture-dirty"
rm -rf "$FIX_DIRTY"
mkdir -p "$FIX_DIRTY/home"
setup_fake_ws_repo "$FIX_DIRTY/ws-fake"
# Dirty the fixture: stage an uncommitted change.
echo "drift" > "$FIX_DIRTY/ws-fake/README"
DIRTY_OUT=$(mktemp -t mesh-p2-dirty-XXXXXX)
MESH_BRIDGE_REPO_DIR="$FIX_DIRTY/ws-fake" \
    HOME="$FIX_DIRTY/home" MESH_STATE_DIR="$FIX_DIRTY/home/.local/state/dev-bootstrap" \
    bash "$BRIDGE" >"$DIRTY_OUT" 2>&1
dirty_rc=$?
assert "step 0: dirty tree → bridge exits 1" "[ $dirty_rc -eq 1 ]"
assert "step 0: error names 'uncommitted changes'" \
    "grep -q 'uncommitted changes' '$DIRTY_OUT'"
assert "step 0: no lock acquired when step 0 aborts" \
    "[ ! -f '$FIX_DIRTY/home/.local/state/dev-bootstrap/migration.lock' ]"
assert "step 0: no snapshot dir created when step 0 aborts" \
    "[ ! -d '$FIX_DIRTY/home/.local/state/dev-bootstrap/snapshots' ]"
rm -rf "$FIX_DIRTY" "$DIRTY_OUT"

# --- Step 0 negative: non-git path aborts with named error ---
echo ""
echo "=== Step 0: non-git WS_DIR aborts ==="
FIX_NOGIT="/tmp/mesh-p2-fixture-nogit"
rm -rf "$FIX_NOGIT"
mkdir -p "$FIX_NOGIT/home" "$FIX_NOGIT/not-a-repo"
NOGIT_OUT=$(mktemp -t mesh-p2-nogit-XXXXXX)
MESH_BRIDGE_REPO_DIR="$FIX_NOGIT/not-a-repo" \
    HOME="$FIX_NOGIT/home" MESH_STATE_DIR="$FIX_NOGIT/home/.local/state/dev-bootstrap" \
    bash "$BRIDGE" >"$NOGIT_OUT" 2>&1
nogit_rc=$?
assert "step 0: non-git path → bridge exits 1" "[ $nogit_rc -eq 1 ]"
assert "step 0: error names 'not a git work tree'" \
    "grep -q 'not a git work tree' '$NOGIT_OUT'"
rm -rf "$FIX_NOGIT" "$NOGIT_OUT"

# --- Step 4 negative: missing refactor branch aborts ---
echo ""
echo "=== Step 4: missing refactor/install-engine branch aborts ==="
FIX_NOBRANCH="/tmp/mesh-p2-fixture-nobranch"
rm -rf "$FIX_NOBRANCH"
mkdir -p "$FIX_NOBRANCH/home"
# Build a fixture with main only; delete refactor/install-engine from both
# the working tree and the bare origin so step 4's fetch + checkout fails.
setup_fake_ws_repo "$FIX_NOBRANCH/ws-fake"
git -C "$FIX_NOBRANCH/ws-fake" branch -D refactor/install-engine >/dev/null 2>&1
git --git-dir="$FIX_NOBRANCH/ws-fake.origin.bare" branch -D refactor/install-engine >/dev/null 2>&1
NOBRANCH_OUT=$(mktemp -t mesh-p2-nobranch-XXXXXX)
MESH_BRIDGE_REPO_DIR="$FIX_NOBRANCH/ws-fake" \
    HOME="$FIX_NOBRANCH/home" MESH_STATE_DIR="$FIX_NOBRANCH/home/.local/state/dev-bootstrap" \
    bash "$BRIDGE" >"$NOBRANCH_OUT" 2>&1
nobranch_rc=$?
# git fetch refusing a nonexistent ref or git checkout refusing the missing
# branch — either way the bridge must not declare success.
assert "step 4: missing refactor branch → bridge exits non-zero" "[ $nobranch_rc -ne 0 ]"
assert "step 4: bridge did NOT print 'Migration complete' on missing branch" \
    "! grep -q 'Migration complete' '$NOBRANCH_OUT'"
rm -rf "$FIX_NOBRANCH" "$FIX_NOBRANCH.origin.bare" "$NOBRANCH_OUT"

# --- H5 fix: removal-abort actually invokes bridge's check_no_removals function ---
echo ""
echo "=== Removal-abort scenario (exercises bridge step-8 code) ==="
# Source bridge as library (no-op early-return), pre-populate snapshot dir
# with DIVERGENT before/after, then call check_no_removals directly.
SNAP_RM=$(mktemp -d -t mesh-p2-snap-rm-XXXXXX)
printf 'foo\nbar\nbaz\n' > "$SNAP_RM/brew-formula.txt"
printf 'foo\nbaz\n'      > "$SNAP_RM/brew-formula.after.txt"  # 'bar' removed
(
    MESH_BRIDGE_LIB_ONLY=1
    . "$BRIDGE"
    set +e   # bridge sources with `set -e`; disable AFTER source for our test
    check_no_removals "$SNAP_RM" 2>/tmp/p2-removal-err
    rc=$?
    echo "removal-check rc: $rc"
    grep -q 'bar' /tmp/p2-removal-err || exit 9
    [ $rc -eq 1 ] || exit 8
    exit 0
)
rm_rc=$?
assert "bridge check_no_removals() returns 1 + reports 'bar' on divergent snapshot" \
    "[ $rm_rc -eq 0 ]"

# Inverse: identical before/after → check_no_removals returns 0
SNAP_OK=$(mktemp -d -t mesh-p2-snap-ok-XXXXXX)
printf 'foo\nbar\nbaz\n' > "$SNAP_OK/brew-formula.txt"
cp "$SNAP_OK/brew-formula.txt" "$SNAP_OK/brew-formula.after.txt"
(
    MESH_BRIDGE_LIB_ONLY=1
    set +e
    . "$BRIDGE"
    check_no_removals "$SNAP_OK"
    exit $?
)
assert "bridge check_no_removals() returns 0 on identical snapshots" "[ $? -eq 0 ]"

# --- H-2 fix (checkpoint-2): multi-manager + missing-snapshot tests ---
# Scenario A: only apt before-snapshot exists, after missing → abort.
SNAP_H2A=$(mktemp -d -t mesh-p2-h2a-XXXXXX)
printf 'pkg1\npkg2\n' > "$SNAP_H2A/apt.txt"
# Intentionally no apt.after.txt
(
    MESH_BRIDGE_LIB_ONLY=1
    set +e
    . "$BRIDGE"
    check_no_removals "$SNAP_H2A" 2>/tmp/p2-h2a-err
    exit $?
)
h2a_rc=$?
assert "H-2: apt before-snapshot WITHOUT after-snapshot triggers abort (rc=1)" \
    "[ $h2a_rc -eq 1 ]"
assert "H-2: apt missing-after error mentions 'apt'" \
    "grep -q apt /tmp/p2-h2a-err"

# Scenario B: only npm-global before exists, after diverges (one pkg removed).
SNAP_H2B=$(mktemp -d -t mesh-p2-h2b-XXXXXX)
printf 'mdprobe\nclaude-mem\nrtk\n' > "$SNAP_H2B/npm-global.txt"
printf 'mdprobe\nrtk\n'             > "$SNAP_H2B/npm-global.after.txt"
(
    MESH_BRIDGE_LIB_ONLY=1
    set +e
    . "$BRIDGE"
    check_no_removals "$SNAP_H2B" 2>/tmp/p2-h2b-err
    exit $?
)
h2b_rc=$?
assert "H-2: npm-global removal (mixed-manager) detected (rc=1)" \
    "[ $h2b_rc -eq 1 ]"
assert "H-2: npm-global removal mentions 'claude-mem'" \
    "grep -q claude-mem /tmp/p2-h2b-err"

# Scenario C: tool absent (no before-snapshot, no after-snapshot) → skip silently.
SNAP_H2C=$(mktemp -d -t mesh-p2-h2c-XXXXXX)
# Empty dir: no manager files at all → manager absent → check returns 0.
(
    MESH_BRIDGE_LIB_ONLY=1
    set +e
    . "$BRIDGE"
    check_no_removals "$SNAP_H2C"
    exit $?
)
assert "H-2: empty snapshot dir (no managers in use) returns 0" "[ $? -eq 0 ]"

# --- C-1 fix (checkpoint-2): re-run preserves .mesh-migrate backup ---
# Bridge must NOT overwrite an existing .mesh-migrate. Re-run scenario:
# 1st run migrates dotfiles-managed: → mesh-managed: and saves pre-migration backup.
# 2nd run (after lock released on EXIT) must NOT clobber backup with post-migration text.
echo ""
echo "=== Re-run safety (C-1) ==="
FIX_RERUN="/tmp/mesh-p2-fixture-rerun"
rm -rf "$FIX_RERUN"
mkdir -p "$FIX_RERUN/home"
cat > "$FIX_RERUN/home/.bashrc" <<'EOF'
# dotfiles-managed: 30-shell start
export PS1='\u@\h:\w\$ '
# dotfiles-managed: 30-shell end
EOF
# Build TWO fixture repos — each run mutates branch state, so a second run
# against the same ws-fake would find HEAD already on refactor/install-engine
# and step 4 would no-op. To prove C-1 re-run safety on markers we use a
# fresh fixture for each run; the lock is shared via MESH_STATE_DIR.
setup_fake_ws_repo "$FIX_RERUN/ws-fake-1"
setup_fake_ws_repo "$FIX_RERUN/ws-fake-2"
# Run 1
MESH_BRIDGE_REPO_DIR="$FIX_RERUN/ws-fake-1" \
    HOME="$FIX_RERUN/home" MESH_STATE_DIR="$FIX_RERUN/home/.local/state/dev-bootstrap" \
    bash "$BRIDGE" >/dev/null 2>&1
rerun1_rc=$?
# Run 2 (after lock released on EXIT trap)
MESH_BRIDGE_REPO_DIR="$FIX_RERUN/ws-fake-2" \
    HOME="$FIX_RERUN/home" MESH_STATE_DIR="$FIX_RERUN/home/.local/state/dev-bootstrap" \
    bash "$BRIDGE" >/dev/null 2>&1
rerun2_rc=$?
assert "C-1: bridge first run succeeds" "[ $rerun1_rc -eq 0 ]"
assert "C-1: bridge second run also succeeds" "[ $rerun2_rc -eq 0 ]"
assert "C-1: .mesh-migrate backup preserves PRE-migration content after re-run" \
    "grep -q 'dotfiles-managed:' '$FIX_RERUN/home/.bashrc.mesh-migrate'"
assert "C-1: .bashrc is migrated (mesh-managed: present)" \
    "grep -q 'mesh-managed:' '$FIX_RERUN/home/.bashrc'"
rm -rf "$FIX_RERUN" "$FIX_RERUN/ws-fake-1.origin.bare" "$FIX_RERUN/ws-fake-2.origin.bare"

# --- Mutation test for C-1: remove the guard and assert backup gets clobbered ---
# Sanity-check that the C-1 fix is load-bearing, not cosmetic.
echo ""
echo "=== Mutation: remove C-1 guard → assert backup IS clobbered ==="
BRIDGE_BROKEN=$(mktemp -t mesh-p2-bridge-broken-XXXXXX.sh)
# Strip the `[ -f "$f.mesh-migrate" ] ||` guard from the cp line via python3
# (BSD sed escaping is unreliable across platforms).
python3 - "$BRIDGE" "$BRIDGE_BROKEN" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = '[ -f "$f.mesh-migrate" ] || cp "$f" "$f.mesh-migrate"'
repl   = 'cp "$f" "$f.mesh-migrate"'
if needle not in src:
    print("MUTATION_TARGET_MISSING", file=sys.stderr)
    sys.exit(2)
open(sys.argv[2], "w").write(src.replace(needle, repl))
PY
mutation_target_rc=$?
chmod +x "$BRIDGE_BROKEN"
FIX_MUT="/tmp/mesh-p2-fixture-mut"
rm -rf "$FIX_MUT"
mkdir -p "$FIX_MUT/home"
cat > "$FIX_MUT/home/.bashrc" <<'EOF'
# dotfiles-managed: 30-shell start
# dotfiles-managed: 30-shell end
EOF
# Two fresh fixture repos so step 4 (real branch checkout) doesn't no-op
# on the second run — exact same reasoning as the C-1 re-run test above.
setup_fake_ws_repo "$FIX_MUT/ws-fake-1"
setup_fake_ws_repo "$FIX_MUT/ws-fake-2"
MESH_BRIDGE_REPO_DIR="$FIX_MUT/ws-fake-1" \
    HOME="$FIX_MUT/home" MESH_STATE_DIR="$FIX_MUT/home/.local/state/dev-bootstrap" \
    bash "$BRIDGE_BROKEN" >/dev/null 2>&1
MESH_BRIDGE_REPO_DIR="$FIX_MUT/ws-fake-2" \
    HOME="$FIX_MUT/home" MESH_STATE_DIR="$FIX_MUT/home/.local/state/dev-bootstrap" \
    bash "$BRIDGE_BROKEN" >/dev/null 2>&1
# Backup file must exist (sanity for mutation harness itself).
assert "C-1 mutation harness: broken bridge still produced backup file" \
    "[ -f '$FIX_MUT/home/.bashrc.mesh-migrate' ] && [ $mutation_target_rc -eq 0 ]"
# With C-1 guard removed, second cp overwrites the backup with post-migration content.
if [ -f "$FIX_MUT/home/.bashrc.mesh-migrate" ] && \
   ! grep -q 'dotfiles-managed:' "$FIX_MUT/home/.bashrc.mesh-migrate"; then
    pass=$((pass+1))
    echo "  PASS: mutation confirmed C-1 fix is load-bearing (backup clobbered without guard)"
else
    fail=$((fail+1))
    fails="$fails\n  FAIL: C-1 mutation didn't take effect — fix may be cosmetic"
    echo "  FAIL: C-1 mutation didn't take effect — fix may be cosmetic"
fi
rm -rf "$FIX_MUT"
rm -f "$BRIDGE_BROKEN"

rm -rf "$SNAP_RM" "$SNAP_OK" "$SNAP_H2A" "$SNAP_H2B" "$SNAP_H2C" \
    /tmp/p2-removal-err /tmp/p2-h2a-err /tmp/p2-h2b-err

# --- CX-H1 (checkpoint-3): atomic lock acquisition (race-safe) ---
# The previous `[ -f LOCK ] && touch LOCK` pattern was check-then-touch — two
# bridges could both pass the `-f` check before either created the file.
# The fix uses noclobber (`set -C; : > LOCK`) which opens with O_EXCL atomically.
echo ""
echo "=== CX-H1: lock acquisition is atomic ==="

# Test A: primitive — back-to-back acquisition on same file → second must fail.
LOCK_TEST=$(mktemp -t mesh-p2-lock-XXXXXX)
rm -f "$LOCK_TEST"   # mktemp creates the file; we want a clean slate
( set -C; : > "$LOCK_TEST" ) 2>/dev/null
prim_a_rc=$?
( set -C; : > "$LOCK_TEST" ) 2>/dev/null
prim_b_rc=$?
assert "CX-H1: first noclobber acquisition succeeds" "[ $prim_a_rc -eq 0 ]"
assert "CX-H1: second noclobber acquisition refused (EEXIST)" "[ $prim_b_rc -ne 0 ]"
rm -f "$LOCK_TEST"

# Test B: real bridge under concurrency. To force the critical sections to
# overlap, we inject `sleep 1` AFTER the metadata write but before EXIT trap
# fires (which releases the lock). Then launch 2 bridges in parallel and
# assert exactly one wins. Without atomic acquisition, the original
# check-then-touch raced and BOTH would succeed (Codex's CX-H1 repro).
BRIDGE_SLOW=$(mktemp -t mesh-p2-bridge-slow-XXXXXX.sh)
python3 - "$BRIDGE" "$BRIDGE_SLOW" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = 'echo "[step 1] lock acquired: $LOCK"'
repl   = 'echo "[step 1] lock acquired: $LOCK"\nsleep 1   # CX-H1 race amplifier (test-only injection)'
if needle not in src:
    print("MUTATION_TARGET_MISSING", file=sys.stderr); sys.exit(2)
open(sys.argv[2], "w").write(src.replace(needle, repl))
PY
race_inject_rc=$?
chmod +x "$BRIDGE_SLOW"
assert "CX-H1: race-amplifier injection succeeded (sleep inserted post-acquire)" \
    "[ $race_inject_rc -eq 0 ]"

FIX_RACE="/tmp/mesh-p2-fixture-race"
rm -rf "$FIX_RACE"
mkdir -p "$FIX_RACE/home"
cat > "$FIX_RACE/home/.bashrc" <<'EOF'
# dotfiles-managed: start
# dotfiles-managed: end
EOF
# Two fresh fixture repos — the loser bails on lock contention before step 4,
# the winner does a real checkout. Either way both need a valid WS_DIR to
# pass step 0; sharing one would have the loser stomp on the winner's tree.
setup_fake_ws_repo "$FIX_RACE/ws-a"
setup_fake_ws_repo "$FIX_RACE/ws-b"
# Launch two slow-bridges concurrently, sharing the same MESH_STATE_DIR (lock target).
MESH_BRIDGE_REPO_DIR="$FIX_RACE/ws-a" \
    HOME="$FIX_RACE/home" MESH_STATE_DIR="$FIX_RACE/state" bash "$BRIDGE_SLOW" >/tmp/p2-race-1 2>&1 &
PID1=$!
MESH_BRIDGE_REPO_DIR="$FIX_RACE/ws-b" \
    HOME="$FIX_RACE/home" MESH_STATE_DIR="$FIX_RACE/state" bash "$BRIDGE_SLOW" >/tmp/p2-race-2 2>&1 &
PID2=$!
wait $PID1; race_rc1=$?
wait $PID2; race_rc2=$?
# Exactly one must win (rc=0), the other must lose (rc=1 lock contention).
winners=0
losers=0
[ $race_rc1 -eq 0 ] && winners=$((winners+1)) || losers=$((losers+1))
[ $race_rc2 -eq 0 ] && winners=$((winners+1)) || losers=$((losers+1))
assert "CX-H1: concurrent bridges — exactly one wins" "[ $winners -eq 1 ] && [ $losers -eq 1 ]"
# The loser's stderr must mention the lock conflict.
if [ $race_rc1 -ne 0 ]; then loser_out=/tmp/p2-race-1; else loser_out=/tmp/p2-race-2; fi
assert "CX-H1: losing concurrent bridge reports lock conflict" \
    "grep -q 'lock exists' '$loser_out'"
rm -rf "$FIX_RACE" /tmp/p2-race-1 /tmp/p2-race-2
rm -f "$BRIDGE_SLOW"

# Test C: mutation — strip the noclobber subshell back to the old `touch`
# pattern → race amplifier exposes both bridges succeeding → proves the
# atomic acquisition is load-bearing, not cosmetic.
echo ""
echo "=== CX-H1 mutation: revert to check-then-touch → both bridges win (BAD) ==="
BRIDGE_RACY=$(mktemp -t mesh-p2-bridge-racy-XXXXXX.sh)
python3 - "$BRIDGE" "$BRIDGE_RACY" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = '''if ! ( set -C; : > "$LOCK" ) 2>/dev/null; then
    echo "ERROR: lock exists at $LOCK — previous run incomplete or another migration is in progress." >&2
    exit 1
fi'''
repl = '''if [ -f "$LOCK" ]; then
    echo "ERROR: lock exists at $LOCK — previous run incomplete." >&2
    exit 1
fi
sleep 1   # CX-H1 race amplifier (test-only)
touch "$LOCK"'''
if needle not in src:
    print("MUTATION_TARGET_MISSING", file=sys.stderr); sys.exit(2)
open(sys.argv[2], "w").write(src.replace(needle, repl))
PY
mut_inject_rc=$?
chmod +x "$BRIDGE_RACY"

FIX_RACY="/tmp/mesh-p2-fixture-racy"
rm -rf "$FIX_RACY"
mkdir -p "$FIX_RACY/home"
cat > "$FIX_RACY/home/.bashrc" <<'EOF'
# dotfiles-managed: start
# dotfiles-managed: end
EOF
setup_fake_ws_repo "$FIX_RACY/ws-a"
setup_fake_ws_repo "$FIX_RACY/ws-b"
MESH_BRIDGE_REPO_DIR="$FIX_RACY/ws-a" \
    HOME="$FIX_RACY/home" MESH_STATE_DIR="$FIX_RACY/state" bash "$BRIDGE_RACY" >/tmp/p2-racy-1 2>&1 &
PIDA=$!
MESH_BRIDGE_REPO_DIR="$FIX_RACY/ws-b" \
    HOME="$FIX_RACY/home" MESH_STATE_DIR="$FIX_RACY/state" bash "$BRIDGE_RACY" >/tmp/p2-racy-2 2>&1 &
PIDB=$!
wait $PIDA; racy_rc1=$?
wait $PIDB; racy_rc2=$?
racy_winners=0
[ $racy_rc1 -eq 0 ] && racy_winners=$((racy_winners+1))
[ $racy_rc2 -eq 0 ] && racy_winners=$((racy_winners+1))
# Without atomic acquisition, BOTH bridges should pass the `-f` check during
# the sleep window → both win → mutation confirmed (race-safety was the fix).
if [ $mut_inject_rc -eq 0 ] && [ $racy_winners -eq 2 ]; then
    pass=$((pass+1))
    echo "  PASS: CX-H1 mutation confirmed (check-then-touch races: both bridges won = $racy_winners)"
elif [ $mut_inject_rc -ne 0 ]; then
    fail=$((fail+1))
    fails="$fails\n  FAIL: CX-H1 mutation harness couldn't inject racy pattern"
    echo "  FAIL: CX-H1 mutation harness couldn't inject racy pattern"
else
    # NOTE: this can flake if the OS schedules the two processes far apart.
    # The 1s sleep window should make this reliable on CI/dev hardware.
    fail=$((fail+1))
    fails="$fails\n  FAIL: CX-H1 mutation didn't expose race (only $racy_winners winner; expected 2 — re-run if flaky)"
    echo "  FAIL: CX-H1 mutation didn't expose race (only $racy_winners winner; expected 2)"
fi
rm -rf "$FIX_RACY" /tmp/p2-racy-1 /tmp/p2-racy-2
rm -f "$BRIDGE_RACY"

# --- CX-M1 (checkpoint-3): active mutation — inject `exit 99` mid-bridge ---
# Codex audit found this was historically claimed but no live harness in
# p2/test.sh. The pipefail + ${PIPESTATUS[0]} capture at the top of this script
# should surface the injected exit; without pipefail the `bridge | sed` pipe
# would mask the bridge rc (sed exits 0).
echo ""
echo "=== CX-M1 mutation: inject exit 99 mid-bridge → pipefail surfaces it ==="
BRIDGE_E99=$(mktemp -t mesh-p2-bridge-e99-XXXXXX.sh)
python3 - "$BRIDGE" "$BRIDGE_E99" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = 'echo "         files with marker rewrites: $renamed_count"'
repl   = 'echo "         files with marker rewrites: $renamed_count"\nexit 99   # CX-M1 test-only injection'
if needle not in src:
    print("MUTATION_TARGET_MISSING", file=sys.stderr); sys.exit(2)
open(sys.argv[2], "w").write(src.replace(needle, repl))
PY
mut_e99_rc=$?
chmod +x "$BRIDGE_E99"
if [ $mut_e99_rc -ne 0 ]; then
    fail=$((fail+1))
    fails="$fails\n  FAIL: CX-M1 P2 mutation harness couldn't inject exit 99"
    echo "  FAIL: CX-M1 P2 mutation harness couldn't inject exit 99"
else
    FIX_E99="/tmp/mesh-p2-fixture-e99"
    rm -rf "$FIX_E99"; mkdir -p "$FIX_E99/home"
    cat > "$FIX_E99/home/.bashrc" <<EOF
# dotfiles-managed: start
# dotfiles-managed: end
EOF
    setup_fake_ws_repo "$FIX_E99/ws-fake"
    MESH_BRIDGE_REPO_DIR="$FIX_E99/ws-fake" \
        HOME="$FIX_E99/home" MESH_STATE_DIR="$FIX_E99/state" \
        bash "$BRIDGE_E99" 2>&1 | sed 's/^/  /' >/dev/null
    exit99_rc=${PIPESTATUS[0]}
    assert "CX-M1 P2: pipefail + PIPESTATUS[0] surfaces injected exit 99" \
        "[ $exit99_rc -eq 99 ]"
    rm -rf "$FIX_E99"
fi
rm -f "$BRIDGE_E99"

# --- CX-M2 (checkpoint-3): all 4 managers produce snapshot files when present ---
# Codex audit found that RESULT.md claimed "Snapshot dir created with all 4
# package manager files", but on this Mac host the bridge only produced
# brew-formula + brew-cask + npm-global (no apt). The H-2 fix made absent
# managers correctly NOT produce empty stub files. This test mocks all 4
# managers as no-op scripts in a sandbox PATH and verifies all 4 .txt files
# materialize when the managers are reachable.
echo ""
echo "=== CX-M2: all 4 managers produce snapshot files when present (fixture) ==="
FIX_M2="/tmp/mesh-p2-fixture-m2"
rm -rf "$FIX_M2"
mkdir -p "$FIX_M2/home" "$FIX_M2/fakebin"
for mgr in brew apt npm; do
    cat > "$FIX_M2/fakebin/$mgr" <<'EOF'
#!/usr/bin/env bash
echo "pkg-a"
echo "pkg-b"
EOF
    chmod +x "$FIX_M2/fakebin/$mgr"
done
cat > "$FIX_M2/home/.bashrc" <<EOF
# dotfiles-managed: start
# dotfiles-managed: end
EOF
setup_fake_ws_repo "$FIX_M2/ws-fake"
MESH_BRIDGE_REPO_DIR="$FIX_M2/ws-fake" \
    PATH="$FIX_M2/fakebin:/usr/bin:/bin" HOME="$FIX_M2/home" \
    MESH_STATE_DIR="$FIX_M2/state" bash "$BRIDGE" >/dev/null 2>&1
m2_rc=$?
SNAP_M2="$FIX_M2/state/snapshots/$(hostname)-pre-migration"
assert "CX-M2: bridge runs cleanly with all 4 mocked managers" "[ $m2_rc -eq 0 ]"
assert "CX-M2: brew-formula.txt created" "[ -f '$SNAP_M2/brew-formula.txt' ]"
assert "CX-M2: brew-cask.txt created"    "[ -f '$SNAP_M2/brew-cask.txt' ]"
assert "CX-M2: apt.txt created"          "[ -f '$SNAP_M2/apt.txt' ]"
assert "CX-M2: npm-global.txt created"   "[ -f '$SNAP_M2/npm-global.txt' ]"
rm -rf "$FIX_M2"

# --- Step 6 + 7 + 9: setup.sh / doctor.sh wired end-to-end ---
# Re-check the main fixture: mock setup.sh and doctor.sh on the refactor
# branch should each have written one trace line into $HOME during the
# initial bridge run (dry-run + apply + doctor — 3 lines).
assert "step 6+7: setup.sh ran twice (dry-run + apply) in main fixture" \
    "[ -f '$FIX/home/.mock-setup-trace' ] && [ \"\$(grep -c '^setup.sh:' '$FIX/home/.mock-setup-trace')\" = '2' ]"
assert "step 6: setup.sh trace shows mode=dryrun" \
    "grep -q 'mode=dryrun' '$FIX/home/.mock-setup-trace'"
assert "step 7: setup.sh trace shows mode=apply" \
    "grep -q 'mode=apply' '$FIX/home/.mock-setup-trace'"
assert "step 9: doctor.sh trace exists in main fixture" \
    "[ -f '$FIX/home/.mock-doctor-trace' ]"

# --- Step 6 negative: setup.sh --dry-run fails ---
echo ""
echo "=== Step 6: setup.sh --dry-run failure aborts ==="
FIX_DRY="/tmp/mesh-p2-fixture-dryfail"
rm -rf "$FIX_DRY"
mkdir -p "$FIX_DRY/home"
setup_fake_ws_repo "$FIX_DRY/ws-fake"
DRY_OUT=$(mktemp -t mesh-p2-dryfail-XXXXXX)
MOCK_SETUP_DRYRUN_RC=7 MESH_BRIDGE_REPO_DIR="$FIX_DRY/ws-fake" \
    HOME="$FIX_DRY/home" MESH_STATE_DIR="$FIX_DRY/home/.local/state/dev-bootstrap" \
    bash "$BRIDGE" >"$DRY_OUT" 2>&1
dry_rc=$?
assert "step 6: dry-run failure → bridge exits non-zero" "[ $dry_rc -ne 0 ]"
assert "step 6: error names 'setup.sh --dry-run failed'" \
    "grep -q 'setup.sh --dry-run failed' '$DRY_OUT'"
assert "step 6: error points at migrate-rollback.sh" \
    "grep -q 'migrate-rollback.sh' '$DRY_OUT'"
assert "step 6: apply trace absent when dry-run aborts" \
    "! grep -q 'mode=apply' '$FIX_DRY/home/.mock-setup-trace'"
rm -rf "$FIX_DRY" "$FIX_DRY.origin.bare" "$DRY_OUT"

# --- Step 7 negative: setup.sh apply fails ---
echo ""
echo "=== Step 7: setup.sh apply failure aborts ==="
FIX_AP="/tmp/mesh-p2-fixture-applyfail"
rm -rf "$FIX_AP"
mkdir -p "$FIX_AP/home"
setup_fake_ws_repo "$FIX_AP/ws-fake"
AP_OUT=$(mktemp -t mesh-p2-applyfail-XXXXXX)
MOCK_SETUP_APPLY_RC=11 MESH_BRIDGE_REPO_DIR="$FIX_AP/ws-fake" \
    HOME="$FIX_AP/home" MESH_STATE_DIR="$FIX_AP/home/.local/state/dev-bootstrap" \
    bash "$BRIDGE" >"$AP_OUT" 2>&1
ap_rc=$?
assert "step 7: apply failure → bridge exits non-zero" "[ $ap_rc -ne 0 ]"
assert "step 7: error names 'setup.sh failed'" \
    "grep -q 'setup.sh failed' '$AP_OUT'"
assert "step 7: error points at migrate-rollback.sh" \
    "grep -q 'migrate-rollback.sh' '$AP_OUT'"
assert "step 7: doctor not invoked when apply fails" \
    "[ ! -f '$FIX_AP/home/.mock-doctor-trace' ]"
rm -rf "$FIX_AP" "$FIX_AP.origin.bare" "$AP_OUT"

# --- Step 9 negative: doctor.sh fails ---
echo ""
echo "=== Step 9: doctor.sh regression aborts ==="
FIX_DOC="/tmp/mesh-p2-fixture-docfail"
rm -rf "$FIX_DOC"
mkdir -p "$FIX_DOC/home"
setup_fake_ws_repo "$FIX_DOC/ws-fake"
DOC_OUT=$(mktemp -t mesh-p2-docfail-XXXXXX)
MOCK_DOCTOR_RC=5 MESH_BRIDGE_REPO_DIR="$FIX_DOC/ws-fake" \
    HOME="$FIX_DOC/home" MESH_STATE_DIR="$FIX_DOC/home/.local/state/dev-bootstrap" \
    bash "$BRIDGE" >"$DOC_OUT" 2>&1
doc_rc=$?
assert "step 9: doctor failure → bridge exits non-zero" "[ $doc_rc -ne 0 ]"
assert "step 9: error mentions 'doctor.sh reported a regression'" \
    "grep -q 'doctor.sh reported a regression' '$DOC_OUT'"
assert "step 9: bridge did NOT print 'Migration complete'" \
    "! grep -q 'Migration complete' '$DOC_OUT'"
rm -rf "$FIX_DOC" "$FIX_DOC.origin.bare" "$DOC_OUT"

# --- Step 8 real diff: package removal between before/after detected ---
# fakebin/brew reads its emit list from a state file. Mock setup.sh
# rewrites that state file to drop 'foo' → after-snapshot is missing 'foo'
# → check_no_removals must abort with rc=1 and name the missing package.
echo ""
echo "=== Step 8: real package-removal diff aborts ==="
FIX_RM="/tmp/mesh-p2-fixture-realrm"
rm -rf "$FIX_RM"
mkdir -p "$FIX_RM/home" "$FIX_RM/fakebin"
# Stateful brew: reads from $FIX_RM/state/brew-formula.list
mkdir -p "$FIX_RM/state"
printf 'foo\nbar\nbaz\n' > "$FIX_RM/state/brew-formula.list"
cat > "$FIX_RM/fakebin/brew" <<EOF
#!/usr/bin/env bash
case "\$2" in
    --formula) cat "$FIX_RM/state/brew-formula.list" ;;
    --cask)    : ;;
    *)         : ;;
esac
EOF
chmod +x "$FIX_RM/fakebin/brew"
# Build fixture with setup.sh that REMOVES 'foo' on apply
setup_fake_ws_repo "$FIX_RM/ws-fake"
# Override the committed setup.sh with one that drops 'foo' from state on apply
(
    cd "$FIX_RM/ws-fake"
    git checkout -q refactor/install-engine
    cat > setup.sh <<EOF
#!/usr/bin/env bash
# mock setup that 'removes' foo from the brew formula list on apply
mode=apply
case "\${1:-}" in --dry-run) mode=dryrun ;; esac
printf 'setup.sh: mode=%s\n' "\$mode" >> "\${HOME:-/tmp}/.mock-setup-trace"
[ "\$mode" = "apply" ] && printf 'bar\nbaz\n' > "$FIX_RM/state/brew-formula.list"
exit 0
EOF
    chmod +x setup.sh
    git add setup.sh
    git -c user.email=t@t -c user.name=t commit -q -m "removing setup.sh"
    git push -q origin refactor/install-engine
    git checkout -q main
)
RM_OUT=$(mktemp -t mesh-p2-realrm-XXXXXX)
PATH="$FIX_RM/fakebin:/usr/bin:/bin" MESH_BRIDGE_REPO_DIR="$FIX_RM/ws-fake" \
    HOME="$FIX_RM/home" MESH_STATE_DIR="$FIX_RM/home/.local/state/dev-bootstrap" \
    bash "$BRIDGE" >"$RM_OUT" 2>&1
rm_rc=$?
assert "step 8: real removal diff → bridge exits non-zero" "[ $rm_rc -ne 0 ]"
assert "step 8: error names removed package 'foo'" \
    "grep -q 'foo' '$RM_OUT'"
assert "step 8: error names brew-formula manager" \
    "grep -q 'brew-formula' '$RM_OUT'"
assert "step 8: bridge did NOT print 'Migration complete'" \
    "! grep -q 'Migration complete' '$RM_OUT'"
SNAP_RM_REAL="$FIX_RM/home/.local/state/dev-bootstrap/snapshots/$(hostname)-pre-migration"
assert "step 8: before-snapshot contains 'foo'" \
    "grep -q '^foo\$' '$SNAP_RM_REAL/brew-formula.txt'"
assert "step 8: after-snapshot OMITS 'foo' (real diff, not synthesized)" \
    "[ -f '$SNAP_RM_REAL/brew-formula.after.txt' ] && ! grep -q '^foo\$' '$SNAP_RM_REAL/brew-formula.after.txt'"
rm -rf "$FIX_RM" "$FIX_RM.origin.bare" "$RM_OUT"

# --- Report ---
total=$((pass + fail))
echo ""
echo "P2 bridge tests: $pass / $total passed"
if [ $fail -gt 0 ]; then
    printf '%b\n' "$fails"
    exit 1
fi
echo "OK"
