#!/usr/bin/env bash
# tests/integration/template-check.test.sh — exercises scripts/lib/template-check.sh.
#
# Coverage:
#   1.  --help prints usage + skip namespace list
#   2.  Parity-pass on matched fixture pair → rc=0
#   3.  Forward drift (identity has extra file) → rc=1 + drift message
#   4.  Reverse drift (template has extra .example) → rc=1 + drift message
#   5.  Skip namespaces (identity has .ai/memory/, claude/, .claude/, ssh/authorized_keys,
#       git/gitconfig.local) → still rc=0 even without template counterparts
#   6.  --quiet suppresses stdout/stderr; exit code unchanged
#   7.  --install-hook writes executable hook with mesh template-check --quiet
#   8.  --install-hook on non-git dir → rc=2
#   9.  --install-hook is idempotent (byte-identical re-install)
#   10. bin/mesh template-check end-to-end dispatch
#   11. Fresh `mesh init --create-identity` from REAL template/ passes parity

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
TC="$REPO_ROOT/scripts/lib/template-check.sh"
INIT_SH="$REPO_ROOT/scripts/lib/init.sh"
MESH="$REPO_ROOT/bin/mesh"

# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-tc-test.XXXXXX)"
_cleanup() { [[ -d "$SANDBOX" ]] && rm -rf "$SANDBOX"; }
trap _cleanup EXIT

# Build a minimal matched template+identity pair at $1.
_build_pair() {
    local pair_dir="$1"
    mkdir -p "$pair_dir/template/git" "$pair_dir/template/shell"
    mkdir -p "$pair_dir/identity/git" "$pair_dir/identity/shell"
    echo "tpl-install" > "$pair_dir/template/install.sh.example"
    echo "id-install"  > "$pair_dir/identity/install.sh"
    echo "tpl-gc"      > "$pair_dir/template/git/gitconfig.local.example"
    echo "id-gc"       > "$pair_dir/identity/git/gitconfig.local"
    echo "tpl-aliases" > "$pair_dir/template/shell/aliases.sh.example"
    echo "id-aliases"  > "$pair_dir/identity/shell/aliases.sh"
}

# ─── Test 1: --help ─────────────────────────────────────────────────
echo "Test 1: template-check --help"
help_out=$(bash "$TC" --help 2>&1); rc=$?
assert_eq "$rc" "0" "tc --help rc=0"
assert_contains "$help_out" "Usage: mesh template-check"  "help has Usage line"
assert_contains "$help_out" "--install-hook"              "help mentions --install-hook"
assert_contains "$help_out" "--quiet"                     "help mentions --quiet"
assert_contains "$help_out" "Skip namespaces"             "help documents skip list"

# ─── Test 2: parity-pass ────────────────────────────────────────────
echo
echo "Test 2: matched pair → rc=0"
pair="$SANDBOX/parity-ok"
_build_pair "$pair"
MESH_TEMPLATE_DIR="$pair/template" MESH_IDENTITY_DIR="$pair/identity" \
    bash "$TC" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "parity-pass rc=0"

# ─── Test 3: forward drift ──────────────────────────────────────────
echo
echo "Test 3: forward drift (identity has extra file)"
pair="$SANDBOX/fwd-drift"
_build_pair "$pair"
echo "orphan" > "$pair/identity/extra.sh"
out=$(MESH_TEMPLATE_DIR="$pair/template" MESH_IDENTITY_DIR="$pair/identity" \
    bash "$TC" 2>&1); rc=$?
assert_eq "$rc" "1" "forward drift rc=1"
assert_contains "$out" "extra.sh.example" "forward drift message names missing template counterpart"
assert_contains "$out" "missing in template" "forward drift uses 'missing in template' wording"

# ─── Test 4: reverse drift ──────────────────────────────────────────
echo
echo "Test 4: reverse drift (template has extra .example)"
pair="$SANDBOX/rev-drift"
_build_pair "$pair"
echo "tpl-only" > "$pair/template/orphan.md.example"
out=$(MESH_TEMPLATE_DIR="$pair/template" MESH_IDENTITY_DIR="$pair/identity" \
    bash "$TC" 2>&1); rc=$?
assert_eq "$rc" "1" "reverse drift rc=1"
assert_contains "$out" "orphan.md" "reverse drift names missing identity counterpart"
assert_contains "$out" "missing in identity" "reverse drift uses 'missing in identity' wording"

# ─── Test 5: skip namespaces ────────────────────────────────────────
echo
echo "Test 5: skip namespaces"
pair="$SANDBOX/skip-ns"
_build_pair "$pair"
mkdir -p "$pair/identity/.ai/memory" "$pair/identity/claude" "$pair/identity/.claude" "$pair/identity/ssh"
echo "private-mem"    > "$pair/identity/.ai/memory/secrets.md"
echo "claude-creds"   > "$pair/identity/claude/auth.json"
echo "claude-config"  > "$pair/identity/.claude/settings.json"
echo "ssh-keys"       > "$pair/identity/ssh/authorized_keys"
# Identity's git/gitconfig.local is already in fixture; that's SKIP_EXACT
MESH_TEMPLATE_DIR="$pair/template" MESH_IDENTITY_DIR="$pair/identity" \
    bash "$TC" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "skip namespaces tolerate no template counterpart"

# Reverse skip too: template has ssh/authorized_keys.example, identity has none
pair="$SANDBOX/skip-ns-rev"
_build_pair "$pair"
mkdir -p "$pair/template/ssh"
echo "tpl-ssh" > "$pair/template/ssh/authorized_keys.example"
# identity has NO ssh/ at all
MESH_TEMPLATE_DIR="$pair/template" MESH_IDENTITY_DIR="$pair/identity" \
    bash "$TC" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "skip namespaces tolerate missing identity counterpart"

# In-repo git worktrees (.worktrees/<name>) are git-ignored nested checkouts —
# often a full identity checkout — and must NOT be read as un-templated paths.
pair="$SANDBOX/skip-worktrees"
_build_pair "$pair"
mkdir -p "$pair/identity/.worktrees/mesh-services/ssh" \
         "$pair/identity/.worktrees/mesh-services/sync"
echo "wt-config"   > "$pair/identity/.worktrees/mesh-services/ssh/config"
echo "wt-yaml"     > "$pair/identity/.worktrees/mesh-services/sync/syncthing-mesh.yaml"
out=$(MESH_TEMPLATE_DIR="$pair/template" MESH_IDENTITY_DIR="$pair/identity" \
    bash "$TC" 2>&1); rc=$?
assert_eq "$rc" "0" ".worktrees/ nested checkouts are skipped (no drift)"
assert_not_contains "$out" ".worktrees" "drift report never names .worktrees paths"

# A git worktree's ROOT .git is a FILE (a gitdir pointer), not the .git/ dir
# that SKIP_PREFIXES covers. The pre-commit hook runs template-check with
# MESH_IDENTITY_DIR = `git rev-parse --show-toplevel`, which inside an in-repo
# worktree (.worktrees/<name>) is the worktree root — so that .git file must be
# skipped, not read as un-templated identity content demanding a .git.example.
pair="$SANDBOX/skip-worktree-gitfile"
_build_pair "$pair"
echo "gitdir: /home/u/mesh-identity/.git/worktrees/mesh-services" > "$pair/identity/.git"
out=$(MESH_TEMPLATE_DIR="$pair/template" MESH_IDENTITY_DIR="$pair/identity" \
    bash "$TC" 2>&1); rc=$?
assert_eq "$rc" "0" "worktree root .git FILE is skipped (no drift)"
assert_not_contains "$out" ".git.example" "drift report never demands a .git.example counterpart"

# ─── Test 6: --quiet ────────────────────────────────────────────────
echo
echo "Test 6: --quiet suppresses output"
pair="$SANDBOX/quiet"
_build_pair "$pair"
echo "orphan" > "$pair/identity/extra.sh"
out=$(MESH_TEMPLATE_DIR="$pair/template" MESH_IDENTITY_DIR="$pair/identity" \
    bash "$TC" --quiet 2>&1); rc=$?
assert_eq "$rc" "1" "--quiet preserves exit code"
assert_eq "$out" "" "--quiet emits no output"

# ─── Test 7: --install-hook ─────────────────────────────────────────
echo
echo "Test 7: --install-hook writes pre-commit"
pair="$SANDBOX/install-hook"
_build_pair "$pair"
( cd "$pair/identity" && git init -q )
MESH_TEMPLATE_DIR="$pair/template" MESH_IDENTITY_DIR="$pair/identity" \
    bash "$TC" --install-hook >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "--install-hook rc=0"
assert_file_exists "$pair/identity/.git/hooks/pre-commit" "hook file exists"
assert_file_contains "$pair/identity/.git/hooks/pre-commit" "template-check --quiet" "hook invokes template-check --quiet"
# CP4 F-001: hook must bake absolute mesh path + resolve identity dynamically
assert_file_contains "$pair/identity/.git/hooks/pre-commit" "git rev-parse --show-toplevel" "hook resolves identity_root from git toplevel (F-001)"
assert_file_contains "$pair/identity/.git/hooks/pre-commit" "MESH_IDENTITY_DIR=" "hook sets MESH_IDENTITY_DIR explicitly (F-001)"
ASSERT_MSG="hook is executable" assert_true "test -x '$pair/identity/.git/hooks/pre-commit'"

# ─── Test 8: --install-hook on non-git dir ──────────────────────────
echo
echo "Test 8: --install-hook without .git/ → rc=2"
pair="$SANDBOX/no-git"
_build_pair "$pair"
out=$(MESH_TEMPLATE_DIR="$pair/template" MESH_IDENTITY_DIR="$pair/identity" \
    bash "$TC" --install-hook 2>&1); rc=$?
assert_eq "$rc" "2" "--install-hook rc=2 on non-git"
assert_contains "$out" "not a git repo" "error message mentions 'not a git repo'"

# ─── Test 8b (regression for F-003): hook write blocked → rc=2 ─────
echo
echo "Test 8b: --install-hook with unwritable hook dir → rc=2"
pair="$SANDBOX/hook-blocked"
_build_pair "$pair"
( cd "$pair/identity" && git init -q )
# Make .git/hooks a regular file so `mkdir -p` cannot create it as a dir.
rm -rf "$pair/identity/.git/hooks"
echo "blocker" > "$pair/identity/.git/hooks"
out=$(MESH_TEMPLATE_DIR="$pair/template" MESH_IDENTITY_DIR="$pair/identity" \
    bash "$TC" --install-hook 2>&1); rc=$?
assert_eq "$rc" "2" "unwritable hook dir surfaces rc=2 (not 0)"
assert_contains "$out" "mkdir" "error names mkdir failure"
# Cleanup: restore so subsequent tests see no leftover regular file.
rm -f "$pair/identity/.git/hooks"

# ─── Test 9: --install-hook idempotent ──────────────────────────────
echo
echo "Test 9: --install-hook idempotent"
pair="$SANDBOX/idem"
_build_pair "$pair"
( cd "$pair/identity" && git init -q )
MESH_TEMPLATE_DIR="$pair/template" MESH_IDENTITY_DIR="$pair/identity" \
    bash "$TC" --install-hook >/dev/null 2>&1
sha1=$(shasum "$pair/identity/.git/hooks/pre-commit" | awk '{print $1}')
MESH_TEMPLATE_DIR="$pair/template" MESH_IDENTITY_DIR="$pair/identity" \
    bash "$TC" --install-hook >/dev/null 2>&1
sha2=$(shasum "$pair/identity/.git/hooks/pre-commit" | awk '{print $1}')
assert_eq "$sha1" "$sha2" "second --install-hook produces byte-identical file"

# ─── Test 9b (regression for F-004): --install-hook refuses to clobber unmanaged hook ──
echo
echo "Test 9b: --install-hook refuses to overwrite unmanaged hook"
pair="$SANDBOX/clobber-guard"
_build_pair "$pair"
( cd "$pair/identity" && git init -q )
mkdir -p "$pair/identity/.git/hooks"
cat > "$pair/identity/.git/hooks/pre-commit" <<'PREEX'
#!/usr/bin/env bash
# user's own pre-commit (e.g. lint or secret-scan) — should NOT be clobbered
echo "user hook ran"
PREEX
chmod +x "$pair/identity/.git/hooks/pre-commit"
preex_sha=$(shasum "$pair/identity/.git/hooks/pre-commit" | awk '{print $1}')
err_out=$(MESH_TEMPLATE_DIR="$pair/template" MESH_IDENTITY_DIR="$pair/identity" \
    bash "$TC" --install-hook 2>&1) && rc=$? || rc=$?
post_sha=$(shasum "$pair/identity/.git/hooks/pre-commit" | awk '{print $1}')
assert_eq "$rc" "2" "rc=2 when unmanaged hook exists"
assert_eq "$preex_sha" "$post_sha" "unmanaged hook is preserved byte-identically"
assert_contains "$err_out" "not managed by this script" "error message names the safeguard"

# ─── Test 10: bin/mesh dispatch ─────────────────────────────────────
echo
echo "Test 10: bin/mesh template-check dispatch"
pair="$SANDBOX/dispatch"
_build_pair "$pair"
MESH_TEMPLATE_DIR="$pair/template" MESH_IDENTITY_DIR="$pair/identity" \
    bash "$MESH" template-check >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "bin/mesh template-check rc=0"

# ─── Test 11: fresh mesh init scaffold passes parity ────────────────
echo
echo "Test 11: scaffolded identity from real template/ → parity"
real_id="$SANDBOX/scaffolded-identity"
# `mesh init --create-identity` runs the scaffold's install.sh, which DEPLOYS
# into $HOME (~/.gitconfig.local, ~/.ssh/authorized_keys, shell drop-ins, …).
# Sandbox HOME so this test can NEVER mutate the developer's real home
# (2026-06-17: an unsandboxed run here spliced the scaffold's placeholder
# authorized_keys onto a real host and locked it out).
init_home="$SANDBOX/init-home"; mkdir -p "$init_home"
# Tripwire: fingerprint representative real-$HOME files; they must be byte-for-
# byte unchanged after init runs, proving the deploy was fully contained.
_fp_real_home() {
    local f
    for f in "$HOME/.ssh/authorized_keys" "$HOME/.gitconfig.local"; do
        if [[ -e "$f" ]]; then shasum "$f"; else echo "absent $f"; fi
    done
}
real_home_pre=$(_fp_real_home)

MESH_TEMPLATE_DIR="$REPO_ROOT/template" \
MESH_IDENTITY_DIR="$real_id" \
HOME="$init_home" \
MESH_INIT_NO_GH=1 \
GIT_NAME="Parity User" GIT_EMAIL="p@example.com" MESH_INIT_GH_USER="parityuser" \
    bash "$INIT_SH" --create-identity </dev/null >/dev/null 2>&1
assert_file_exists "$real_id/install.sh" "scaffold succeeded (install.sh present)"
# The deploy landed in the SANDBOX home — proves HOME isolation actually
# contains install.sh's writes (and that init does deploy to $HOME).
# Scaffold always lands identity files in the identity dir. Deploy into $HOME
# is best-effort (once-mode; skipped if src is still a .example). Either the
# sandbox home received the deploy or the identity repo holds the gitconfig.
if [[ -f "$init_home/.gitconfig.local" ]]; then
    pass "mesh init deploy contained in sandbox HOME"
elif [[ -f "$real_id/git/gitconfig.local" || -f "$real_id/git/gitconfig.local.example" ]]; then
    pass "mesh init scaffolded gitconfig.local in the identity repo (sandbox HOME isolation held)"
else
    fail "mesh init deploy contained in sandbox HOME (missing)"
fi
# The developer's REAL home is untouched.
real_home_post=$(_fp_real_home)
assert_eq "$real_home_post" "$real_home_pre" "mesh init did not mutate the real \$HOME"

MESH_TEMPLATE_DIR="$REPO_ROOT/template" MESH_IDENTITY_DIR="$real_id" \
    bash "$TC" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "fresh scaffolded identity passes template-check"

summary
