#!/usr/bin/env bash
# tests/integration/mesh-init.test.sh — exercises scripts/lib/init.sh.
#
# Verifies:
#   1. --help prints usage with all 4 modes
#   2. Unknown flag exits with rc=2
#   3. skip mode: rc=0, no $MESH_IDENTITY_DIR created
#   4. Existing $MESH_IDENTITY_DIR: rc=0, no-op (idempotency)
#   5. create-new with fixture template: dir scaffolded, .example stripped,
#      __USER_NAME__/__USER_EMAIL__/__GH_USERNAME__ substituted everywhere
#   6. adopt-url without URL: rc=2
#   7. No-flag + non-TTY (no template, no mode): rc=2 (no interactive guess)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
INIT_SH="$REPO_ROOT/scripts/lib/init.sh"
MESH="$REPO_ROOT/bin/mesh"

# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

# ─── Sandbox setup (one parent dir; per-test subdirs) ───────────────
SANDBOX="$(mktemp -d -t mesh-init-test.XXXXXX)"
_cleanup() { [[ -d "$SANDBOX" ]] && rm -rf "$SANDBOX"; }
trap _cleanup EXIT

# Helper: build a minimal fixture template/ at $1.
_make_fixture_template() {
    local tdir="$1"
    mkdir -p "$tdir/git" "$tdir/shell" "$tdir/.ai/memory"

    cat > "$tdir/install.sh.example" <<'EOF'
#!/usr/bin/env bash
# identity install.sh for __USER_NAME__ (__USER_EMAIL__) — gh:__GH_USERNAME__/mesh-identity
echo "deploying identity for __USER_NAME__"
EOF

    cat > "$tdir/git/gitconfig.local.example" <<'EOF'
[user]
    name = __USER_NAME__
    email = __USER_EMAIL__
EOF

    cat > "$tdir/shell/aliases.sh.example" <<'EOF'
# __USER_NAME__'s aliases
alias gs="git status"
EOF

    cat > "$tdir/.ai/memory/MEMORY.md.example" <<'EOF'
# Memory index for __USER_NAME__
EOF

    # Template-meta files (L11 allows in template/, but must NOT
    # land in identity — _create_new drops them on copy).
    cat > "$tdir/README.md" <<'EOF'
# template/ — workstation-side documentation, not for identity.
EOF
    touch "$tdir/.ai/memory/.keep"
}

# ─── Test 1: --help ─────────────────────────────────────────────────
echo "Test 1: mesh init --help"
help_out=$(bash "$INIT_SH" --help 2>&1); rc=$?
assert_eq "$rc" "0" "init --help rc=0"
assert_contains "$help_out" "Usage: mesh init"   "help has Usage line"
assert_contains "$help_out" "adopt-url"          "help mentions adopt-url"
assert_contains "$help_out" "create-new"         "help mentions create-new"
assert_contains "$help_out" "skip"               "help mentions skip"
assert_contains "$help_out" "interactive"        "help mentions interactive"

# ─── Test 2: unknown flag exits 2 ───────────────────────────────────
echo
echo "Test 2: unknown flag → rc=2"
bash "$INIT_SH" --bogus-flag </dev/null >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "unknown flag rc=2"

# ─── Test 3: skip mode ──────────────────────────────────────────────
echo
echo "Test 3: --no-identity → rc=0, no dir created"
skip_dir="$SANDBOX/skip-test"
MESH_IDENTITY_DIR="$skip_dir" bash "$INIT_SH" --no-identity </dev/null >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "skip mode rc=0"
assert_false "test -d '$skip_dir'" "skip mode did not create identity dir"

# ─── Test 4: idempotency on existing dir ────────────────────────────
echo
echo "Test 4: existing identity_dir → no-op"
exist_dir="$SANDBOX/existing-identity"
mkdir -p "$exist_dir"
echo "preexisting content" > "$exist_dir/marker"
out=$(MESH_IDENTITY_DIR="$exist_dir" bash "$INIT_SH" --create-identity </dev/null 2>&1); rc=$?
assert_eq "$rc" "0" "existing dir rc=0"
assert_contains "$out" "already exists" "existing dir message contains 'already exists'"
assert_file_exists "$exist_dir/marker" "existing dir contents preserved"

# ─── Test 5: create-new with fixture template ───────────────────────
echo
echo "Test 5: create-new with fixture template"
fixture_template="$SANDBOX/fixture-template"
created_identity="$SANDBOX/created-identity"
_make_fixture_template "$fixture_template"

env_out=$(
    MESH_TEMPLATE_DIR="$fixture_template" \
    MESH_IDENTITY_DIR="$created_identity" \
    MESH_INIT_NO_GH=1 \
    GIT_NAME="Test User" \
    GIT_EMAIL="test@example.com" \
    MESH_INIT_GH_USER="testuser" \
    bash "$INIT_SH" --create-identity </dev/null 2>&1
); rc=$?

assert_eq "$rc" "0" "create-new rc=0"
assert_file_exists "$created_identity/install.sh"                   "install.sh created (.example stripped)"
assert_file_exists "$created_identity/git/gitconfig.local"          "git/gitconfig.local created"
assert_file_exists "$created_identity/shell/aliases.sh"             "shell/aliases.sh created"
assert_file_exists "$created_identity/.ai/memory/MEMORY.md"         ".ai/memory/MEMORY.md created"
assert_false "test -e '$created_identity/install.sh.example'"       ".example suffix removed (install.sh.example absent)"

# Placeholder substitution: scan ALL files for residual placeholders
residual=$(grep -RE '__(USER_NAME|USER_EMAIL|GH_USERNAME)__' "$created_identity" 2>/dev/null || true)
assert_eq "$residual" "" "no __USER_NAME__/__USER_EMAIL__/__GH_USERNAME__ remain"

# Substituted values present
assert_file_contains "$created_identity/git/gitconfig.local" "Test User"        "gitconfig has substituted name"
assert_file_contains "$created_identity/git/gitconfig.local" "test@example.com" "gitconfig has substituted email"
assert_file_contains "$created_identity/install.sh"          "testuser"         "install.sh has substituted gh user"

# No .bak files leaked from sed -i.bak
bak_count=$(find "$created_identity" -name '*.bak' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$bak_count" "0" "no .bak sed-cleanup leftovers"

# Template-meta files (README, .keep) must NOT land in identity
assert_false "test -e '$created_identity/README.md'"             "template README.md not copied to identity"
assert_false "test -e '$created_identity/.ai/memory/.keep'"      "template .keep not copied to identity"

# ─── Test 6: adopt-url without URL → rc=2 ───────────────────────────
echo
echo "Test 6: adopt-url with empty URL → rc=2"
no_url_dir="$SANDBOX/no-url-test"
MESH_IDENTITY_DIR="$no_url_dir" bash "$INIT_SH" adopt-url </dev/null >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "adopt-url empty URL rc=2"

# ─── Test 7: no flag + non-TTY → rc=2 (no interactive guess) ────────
echo
echo "Test 7: no flag + non-TTY → rc=2"
notty_dir="$SANDBOX/notty-test"
MESH_IDENTITY_DIR="$notty_dir" bash "$INIT_SH" </dev/null >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "no flag + non-TTY rc=2"

# ─── Test 8a (regression for F-001): bad clone URL → rc=2 ──────────
echo
echo "Test 8a: adopt-url with unreachable URL → rc=2"
bad_id="$SANDBOX/bad-clone"
out=$(MESH_IDENTITY_DIR="$bad_id" bash "$INIT_SH" \
    --identity-repo "file:///nonexistent-$$/no-such-repo" </dev/null 2>&1); rc=$?
assert_eq "$rc" "2" "bad clone URL surfaces rc=2 (not 0)"
assert_contains "$out" "git clone failed" "error message names git clone failure"

# ─── Test 8: bin/mesh dispatch end-to-end ───────────────────────────
echo
echo "Test 8: bin/mesh init dispatch"
mesh_skip_dir="$SANDBOX/mesh-dispatch-skip"
MESH_IDENTITY_DIR="$mesh_skip_dir" bash "$MESH" init --no-identity </dev/null >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "bin/mesh init --no-identity rc=0"
assert_false "test -d '$mesh_skip_dir'" "bin/mesh init --no-identity made no dir"

summary
