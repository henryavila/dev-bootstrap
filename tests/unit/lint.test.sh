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
# Advisory lints (rc=0 + non-empty stdout, e.g. L17) are tolerated; only
# real-failure output (lines matching `L<NN>: ...` without `(advisory)`)
# fails the clean-tree contract.
echo "Orchestrator on clean tree"
out=$(bash "$ORCH" 2>&1); rc=$?
assert_eq "$rc" "0" "scripts/lib/lint.sh rc=0 on clean tree"
non_advisory=$(printf '%s' "$out" | grep -vE '^(L[0-9]+ \(advisory\):|$|lint: 0 lint)' || true)
assert_eq "$non_advisory" "" "scripts/lib/lint.sh emits only advisory lines on clean tree"

# ─── Advisory lint contract (L17) ──────────────────────────────────
# L17 detects the inline-script-call migration backlog. After the 11-topic
# mass migration (commits b871d58..2b83ea9) the backlog is empty: L17 must
# exit 0 with NO output on the current tree. Inject a synthetic candidate
# to prove the detection logic still works, then assert the advisory line
# is emitted when something matches.
echo
echo "L17 advisory: silent when backlog is empty"
out=$(bash "$LINTS_DIR/L17-inline-script-call.sh" 2>&1); rc=$?
assert_eq "$rc" "0" "L17 advisory exits 0 on clean tree"
assert_eq "$out" ""  "L17 emits no output now that the migration backlog is empty"

echo
echo "L17 detection still active (synthetic candidate)"
mkdir -p "$REPO_ROOT/topics/__lint-injection__"
__l17_inject() {
    local path="$1" content="$2"
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
}
__l17_inject "$REPO_ROOT/topics/__lint-injection__/install.mac.sh" \
    $'#!/usr/bin/env bash\nbash "$HERE/scripts/install-something.sh"'
out=$(bash "$LINTS_DIR/L17-inline-script-call.sh" 2>&1); rc=$?
rm -f "$REPO_ROOT/topics/__lint-injection__/install.mac.sh"
assert_eq "$rc" "0" "L17 advisory exits 0 even with finding (advisory mode)"
assert_contains "$out" "L17 (advisory):" "L17 emits advisory line for synthetic candidate"
assert_contains "$out" "type:custom" "L17 advisory points at the items.yaml migration target"

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

# L01 — hardcoded $HOME/dotfiles without envar fallback
echo
echo "L01 injection: bare \$HOME/dotfiles path"
_inject "$REPO_ROOT/topics/__lint-injection__/violation.sh" \
    $'#!/usr/bin/env bash\ncd $HOME/dotfiles || exit 1'
_run_lint_expect_fail "L01-no-hardcoded-dotfiles-path.sh" "L01:"
rm -f "$REPO_ROOT/topics/__lint-injection__/violation.sh"

# L01 — allowlist contract: ${VAR:-$HOME/dotfiles} must NOT trigger
echo
echo "L01 allowlist contract: \${VAR:-\$HOME/dotfiles} accepted"
_inject "$REPO_ROOT/topics/__lint-injection__/violation.sh" \
    $'#!/usr/bin/env bash\ndir="${MESH_IDENTITY_DIR:-$HOME/dotfiles}"'
out=$(bash "$LINTS_DIR/L01-no-hardcoded-dotfiles-path.sh" 2>&1); rc=$?
assert_eq "$rc" "0" "L01 accepts \${VAR:-\$HOME/dotfiles} fallback"
rm -f "$REPO_ROOT/topics/__lint-injection__/violation.sh"

# L05 — rm -rf of literal path (no trap, no allowlisted var)
echo
echo "L05 injection: bare 'rm -rf /tmp/foo' literal"
_inject "$REPO_ROOT/topics/__lint-injection__/violation.sh" \
    $'#!/usr/bin/env bash\nrm -rf /tmp/foo'
_run_lint_expect_fail "L05-no-unguarded-rm-rf.sh" "L05:"
rm -f "$REPO_ROOT/topics/__lint-injection__/violation.sh"

# L05 — allowlist contract: trap 'rm -rf …' is accepted
echo
echo "L05 allowlist contract: trap 'rm -rf' accepted"
_inject "$REPO_ROOT/topics/__lint-injection__/violation.sh" \
    $'#!/usr/bin/env bash\ntrap \'rm -rf "$tmp"\' EXIT'
out=$(bash "$LINTS_DIR/L05-no-unguarded-rm-rf.sh" 2>&1); rc=$?
assert_eq "$rc" "0" "L05 accepts trap cleanup pattern"
rm -f "$REPO_ROOT/topics/__lint-injection__/violation.sh"

# L08 — bare uninstall.sh reference (post Phase 2 rename)
echo
echo "L08 injection: uninstall.sh reference"
_inject "$REPO_ROOT/topics/__lint-injection__/violation.sh" \
    $'#!/usr/bin/env bash\nbash scripts/lib/uninstall.sh'
_run_lint_expect_fail "L08-no-uninstall-sh.sh" "L08:"
rm -f "$REPO_ROOT/topics/__lint-injection__/violation.sh"

# L12 — workstation code references identity-only path
echo
echo "L12 injection: CLAUDE.md reference in workstation code"
_inject "$REPO_ROOT/topics/__lint-injection__/violation.sh" \
    $'#!/usr/bin/env bash\ncat "$HOME/CLAUDE.md"'
_run_lint_expect_fail "L12-no-identity-paths.sh" "L12:"
rm -f "$REPO_ROOT/topics/__lint-injection__/violation.sh"

# L09 — custom-script missing required function
echo
echo "L09 injection: custom-script missing verify() and rollback()"
mkdir -p "$REPO_ROOT/topics/__lint-injection__"
# L18 forbids `check:` on type:custom, so the L09 fixture below intentionally
# omits manifest check: (irrelevant to L09's verify/rollback check anyway).
_inject "$REPO_ROOT/topics/__lint-injection__/items.yaml" \
    $'- name: bad-custom\n  type: custom\n  script: "./bad-custom.sh"\n  desc: "missing verify+rollback"\n  platforms: [mac]'
_inject "$REPO_ROOT/topics/__lint-injection__/bad-custom.sh" \
    $'#!/usr/bin/env bash\ncheck() { :; }\ninstall() { :; }'
_run_lint_expect_fail "L09-custom-script-contract.sh" "L09:"
rm -f "$REPO_ROOT/topics/__lint-injection__/items.yaml" \
      "$REPO_ROOT/topics/__lint-injection__/bad-custom.sh"

# L18 — type:custom item with manifest check: field (engine override shadow)
echo
echo "L18 injection: items.yaml with type:custom + check:"
_inject "$REPO_ROOT/topics/__lint-injection__/items.yaml" \
    $'- name: shadow-custom\n  type: custom\n  script: "./shadow.sh"\n  check: "command -v whatever"\n  desc: "shadow check"'
_inject "$REPO_ROOT/topics/__lint-injection__/shadow.sh" \
    $'#!/usr/bin/env bash\ncheck() { :; }\ninstall() { :; }\nverify() { :; }\nrollback() { :; }'
_run_lint_expect_fail "L18-no-manifest-check-on-custom.sh" "L18:"
rm -f "$REPO_ROOT/topics/__lint-injection__/items.yaml" \
      "$REPO_ROOT/topics/__lint-injection__/shadow.sh"

# L18 — type:apt with check: is allowed (manifest override is intentional there)
echo
echo "L18 allowlist contract: non-custom type with check: is accepted"
_inject "$REPO_ROOT/topics/__lint-injection__/items.yaml" \
    $'- name: ok-apt\n  type: apt\n  spec: htop\n  check: "command -v htop"'
out=$(bash "$LINTS_DIR/L18-no-manifest-check-on-custom.sh" 2>&1); rc=$?
assert_eq "$rc" "0" "L18 ignores check: on non-custom types"
rm -f "$REPO_ROOT/topics/__lint-injection__/items.yaml"

echo
summary
