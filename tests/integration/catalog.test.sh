#!/usr/bin/env bash
# tests/integration/catalog.test.sh — exercises scripts/lib/catalog.sh.
#
# Verifies:
#   1. Fresh generation produces all expected files.
#   2. Re-generation is byte-identical (deterministic / drift-free).
#   3. cli.txt contains the subcommands we just added in Phase 5 (lint, catalog).
#   4. drivers.txt matches scripts/lib/installers/*.sh contents.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
CATALOG="$REPO_ROOT/scripts/lib/catalog.sh"
OUT="$REPO_ROOT/.catalog"
SNAPSHOT="$REPO_ROOT/.catalog.snapshot"

# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

# ─── Cleanup safety net ─────────────────────────────────────────────
_cleanup() {
    [[ -d "$SNAPSHOT" ]] && rm -rf "$SNAPSHOT"
}
trap _cleanup EXIT

# ─── Test 1: fresh generation ──────────────────────────────────────
echo "Fresh generation"
[[ -d "$OUT" ]] && rm -rf "$OUT"
# shellcheck disable=SC2034  # captured to suppress catalog stdout
out=$(bash "$CATALOG" 2>&1); rc=$?
assert_eq "$rc" "0" "catalog.sh fresh-run rc=0"
assert_file_exists "$OUT/resources.txt"     ".catalog/resources.txt exists"
assert_file_exists "$OUT/opt-ins.txt"       ".catalog/opt-ins.txt exists"
assert_file_exists "$OUT/cli.txt"           ".catalog/cli.txt exists"
assert_file_exists "$OUT/drivers.txt"       ".catalog/drivers.txt exists"
assert_file_exists "$OUT/README.md"         ".catalog/README.md exists"

# ─── Test 2: byte-stable re-generation ─────────────────────────────
echo
echo "Byte-stable re-generation"
cp -R "$OUT" "$SNAPSHOT"
bash "$CATALOG" >/dev/null 2>&1
if diff -r "$SNAPSHOT" "$OUT" >/dev/null 2>&1; then
    pass "re-generation is byte-identical"
else
    fail "re-generation drifted between runs"
    diff -r "$SNAPSHOT" "$OUT" || true
fi

# ─── Test 3: cli.txt contents ──────────────────────────────────────
echo
echo "cli.txt content checks"
if grep -q '^lint$' "$OUT/cli.txt"; then
    pass "cli.txt contains 'lint' subcommand"
else
    fail "cli.txt missing 'lint'"
fi
if grep -q '^catalog$' "$OUT/cli.txt"; then
    pass "cli.txt contains 'catalog' subcommand"
else
    fail "cli.txt missing 'catalog'"
fi
if grep -q '^status$' "$OUT/cli.txt"; then
    pass "cli.txt contains 'status' subcommand"
else
    fail "cli.txt missing 'status'"
fi

# ─── Test 4: drivers.txt matches installers ────────────────────────
echo
echo "drivers.txt completeness"
expected=$(find "$REPO_ROOT/scripts/lib/installers" -maxdepth 1 -type f -name '*.sh' \
    | sed -E "s|.*/||; s|\.sh$||" | LC_ALL=C sort)
actual=$(cat "$OUT/drivers.txt")
assert_eq "$actual" "$expected" "drivers.txt matches installers/*.sh listing"

# ─── Test 5: opt-ins.txt sorted + unique ───────────────────────────
echo
echo "opt-ins.txt invariants"
if cmp -s "$OUT/opt-ins.txt" <(LC_ALL=C sort -u < "$OUT/opt-ins.txt"); then
    pass "opt-ins.txt is sorted and unique"
else
    fail "opt-ins.txt not sorted or has duplicates"
fi

# ─── Test 6: README.md counts mapped to correct rows ───────────────
echo
echo "README.md line counts match derived files on their own rows"
res_n=$(wc -l < "$OUT/resources.txt" | tr -d ' ')
opt_n=$(wc -l < "$OUT/opt-ins.txt"   | tr -d ' ')
cli_n=$(wc -l < "$OUT/cli.txt"       | tr -d ' ')
drv_n=$(wc -l < "$OUT/drivers.txt"   | tr -d ' ')

_check_readme_row() {
    local label="$1" count="$2"
    if grep -qF "| [$label]($label) | $count |" "$OUT/README.md"; then
        pass "README.md row for $label references $count"
    else
        fail "README.md row for $label missing count $count"
    fi
}
_check_readme_row "resources.txt" "$res_n"
_check_readme_row "opt-ins.txt"   "$opt_n"
_check_readme_row "cli.txt"       "$cli_n"
_check_readme_row "drivers.txt"   "$drv_n"

echo
summary
