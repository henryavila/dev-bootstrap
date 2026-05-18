#!/usr/bin/env bash
# tests/unit/lint.test.sh — exercises scripts/lib/lint.sh orchestrator and
# the 9 lints shipped in Phase 5 Task 5.2.
#
# Strategy:
# 1. Orchestrator returns rc=0 on the current clean tree.
# 2. For each Lxx lint with an injectable pattern, write a scratch file under
#    topics/__lint-injection__/ (or scripts/lib/__lint-injection__.sh for L13),
#    run only that lint, expect rc>0 + token "L<NN>:" in stdout, then remove
#    the scratch file before moving on.
# 3. L11 (template/) and L14 (mesh-repos.list) cover the absent-source code
#    path: with the source absent, lint must exit 0 quietly.
#
# All scratch files are placed under sentinel directories named
# __lint-injection__ so a stray run can be reasoned about and cleaned by hand.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LINTS_DIR="$REPO_ROOT/scripts/lib/lints"
ORCH="$REPO_ROOT/scripts/lib/lint.sh"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

# ─── Cleanup safety net ─────────────────────────────────────────────
SCRATCH_DIRS=(
    "$REPO_ROOT/topics/__lint-injection__"
)
SCRATCH_FILES=(
    "$REPO_ROOT/scripts/lib/__lint-injection__.sh"
)
_cleanup() {
    local d f
    for d in "${SCRATCH_DIRS[@]}"; do
        [[ -d "$d" ]] && rm -rf "$d"
    done
    for f in "${SCRATCH_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}
trap _cleanup EXIT

# ─── Clean-tree orchestrator pass ──────────────────────────────────
echo "Orchestrator on clean tree"
out=$(bash "$ORCH" 2>&1); rc=$?
assert_eq "$rc" "0" "scripts/lib/lint.sh rc=0 on clean tree"
assert_eq "$out" "" "scripts/lib/lint.sh emits no output on clean tree"

# ─── Per-lint injection harness ─────────────────────────────────────
mkdir -p "$REPO_ROOT/topics/__lint-injection__"

_inject() {
    local path="$1"; shift
    local content="$1"
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
}

_run_lint_expect_fail() {
    local lint="$1" tag="$2"
    local out rc
    out=$(bash "$LINTS_DIR/$lint" 2>&1); rc=$?
    if (( rc == 0 )); then
        fail "$lint should have flagged $tag (rc=$rc, out=$out)"
        return
    fi
    if [[ "$out" != *"${tag}"* ]]; then
        fail "$lint output missing token '$tag' (out=$out)"
        return
    fi
    pass "$lint flags $tag (rc=$rc)"
}

# ─── Multi-failure exit-code contract ───────────────────────────────
# Orchestrator contract: rc = number of failing lints (capped 125).
# Inject one file that violates exactly L03 (set +e) and L04 (eval $()).
echo
echo "Orchestrator on tree with 2 lint violations"
_inject "$REPO_ROOT/topics/__lint-injection__/multi.sh" \
    $'#!/usr/bin/env bash\nset +e\neval $(echo unsafe)'
out=$(bash "$ORCH" 2>&1); rc=$?
assert_eq "$rc" "2" "scripts/lib/lint.sh rc=N for N=2 failing lints"
rm -f "$REPO_ROOT/topics/__lint-injection__/multi.sh"

# L03 — set +e
echo
echo "L03 injection: set +e"
_inject "$REPO_ROOT/topics/__lint-injection__/violation.sh" \
    $'#!/usr/bin/env bash\nset +e\necho hi'
_run_lint_expect_fail "L03-no-set-plus-e.sh" "L03:"
rm -f "$REPO_ROOT/topics/__lint-injection__/violation.sh"

# L04 — eval $(...)
echo
echo "L04 injection: eval \$(...)"
_inject "$REPO_ROOT/topics/__lint-injection__/violation.sh" \
    $'#!/usr/bin/env bash\neval $(echo unsafe)'
_run_lint_expect_fail "L04-no-eval-cmdsub.sh" "L04:"
rm -f "$REPO_ROOT/topics/__lint-injection__/violation.sh"

# L06 — inline secret
echo
echo "L06 injection: API_KEY long literal"
_inject "$REPO_ROOT/topics/__lint-injection__/violation.sh" \
    $'#!/usr/bin/env bash\nAPI_KEY="abcdefghijklmnopqrstuvwxyz123456"'
_run_lint_expect_fail "L06-no-inline-secrets.sh" "L06:"
rm -f "$REPO_ROOT/topics/__lint-injection__/violation.sh"

# L10 — bootstrap.sh
echo
echo "L10 injection: bootstrap.sh reference"
_inject "$REPO_ROOT/topics/__lint-injection__/violation.sh" \
    $'#!/usr/bin/env bash\nbash bootstrap.sh'
_run_lint_expect_fail "L10-no-bootstrap-sh.sh" "L10:"
rm -f "$REPO_ROOT/topics/__lint-injection__/violation.sh"

# L11 — template/ file not ending in .example
echo
echo "L11 injection: template/ file without .example"
if [[ -d "$REPO_ROOT/template" ]]; then
    _inject "$REPO_ROOT/template/bad-file" "raw content"
    _run_lint_expect_fail "L11-template-files-example.sh" "L11:"
    rm -f "$REPO_ROOT/template/bad-file"
else
    # template/ absent in current tree: confirm skip-if-absent contract.
    out=$(bash "$LINTS_DIR/L11-template-files-example.sh" 2>&1); rc=$?
    assert_eq "$rc" "0" "L11 exits 0 when template/ is absent"
    assert_eq "$out" "" "L11 emits no output when template/ is absent"
fi

# L13 — executable in scripts/lib/
echo
echo "L13 injection: scripts/lib/__lint-injection__.sh with +x"
_inject "$REPO_ROOT/scripts/lib/__lint-injection__.sh" \
    $'# scratch — source-only file marked executable to trigger L13'
chmod +x "$REPO_ROOT/scripts/lib/__lint-injection__.sh"
_run_lint_expect_fail "L13-lib-not-executable.sh" "L13:"
rm -f "$REPO_ROOT/scripts/lib/__lint-injection__.sh"

# L14 — absent file path
echo
echo "L14 contract: skip when mesh-repos.list is absent"
if [[ ! -f "$REPO_ROOT/mesh-repos.list" ]]; then
    out=$(bash "$LINTS_DIR/L14-mesh-repos-two-layer.sh" 2>&1); rc=$?
    assert_eq "$rc" "0" "L14 exits 0 when mesh-repos.list is absent"
    assert_eq "$out" "" "L14 emits no output when mesh-repos.list is absent"
else
    pass "L14 absent-file contract: mesh-repos.list present, skipping absent-path assertion"
fi

# L15 — bash 4 builtin in install.sh (Mac-reachable)
echo
echo "L15 injection: mapfile in install.sh"
_inject "$REPO_ROOT/topics/__lint-injection__/install.sh" \
    $'#!/usr/bin/env bash\nmapfile -t arr < <(echo hi)'
_run_lint_expect_fail "L15-bash32-compat.sh" "L15:"
rm -f "$REPO_ROOT/topics/__lint-injection__/install.sh"

# L16 — grep without -i for mesh-managed marker
echo
echo "L16 injection: grep -q 'mesh-managed:' without -i"
_inject "$REPO_ROOT/topics/__lint-injection__/violation.sh" \
    $'#!/usr/bin/env bash\nif grep -q \'mesh-managed:\' /tmp/file; then :; fi'
_run_lint_expect_fail "L16-marker-case-insensitive.sh" "L16:"
rm -f "$REPO_ROOT/topics/__lint-injection__/violation.sh"

echo
summary
