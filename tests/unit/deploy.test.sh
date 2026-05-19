#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
. "$WS/scripts/lib/deploy.sh"

passed=0; failed=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/src/git"
echo "hello" > "$TMP/src/git/sample"

# Test 1: overwrite mode copies
deploy_one "git/sample|$TMP/dst1|overwrite|0644" "$TMP/src"
got=$(cat "$TMP/dst1"); exp=$'hello'
if [[ "$got" == "$exp" ]]; then passed=$((passed+1)); echo "  ✓ overwrite copies content"
else failed=$((failed+1)); echo "  ✗ overwrite copies content" >&2; fi

# Test 2: once mode skips if exists
echo "preexisting" > "$TMP/dst2"
deploy_one "git/sample|$TMP/dst2|once|0644" "$TMP/src"
got=$(cat "$TMP/dst2")
if [[ "$got" == "preexisting" ]]; then passed=$((passed+1)); echo "  ✓ once mode preserves existing"
else failed=$((failed+1)); echo "  ✗ once mode preserves existing" >&2; fi

# Test 3: managed_block injects between markers
deploy_one "git/sample|$TMP/dst3|managed_block|0644" "$TMP/src"
if grep -q 'mesh-managed: sample' "$TMP/dst3"; then passed=$((passed+1)); echo "  ✓ managed_block injects markers"
else failed=$((failed+1)); echo "  ✗ managed_block injects markers" >&2; fi

# Test 4: overwrite skips when content identical (no backup created)
ls "$TMP" > /tmp/dst1-before
deploy_one "git/sample|$TMP/dst1|overwrite|0644" "$TMP/src"
ls "$TMP" > /tmp/dst1-after
if diff -q /tmp/dst1-before /tmp/dst1-after >/dev/null; then passed=$((passed+1)); echo "  ✓ overwrite skip-if-identical (no backup created)"
else failed=$((failed+1)); echo "  ✗ overwrite skip-if-identical (no backup created)" >&2; fi

# Test 5: overwrite backs up dst when content differs
echo "old content" > "$TMP/dst5"
deploy_one "git/sample|$TMP/dst5|overwrite|0644" "$TMP/src"
backup=$(ls "$TMP"/dst5.bak-* 2>/dev/null | head -1)
got=$(cat "$TMP/dst5")
if [[ -n "$backup" ]] && [[ "$got" == "hello" ]] && grep -q "old content" "$backup"; then passed=$((passed+1)); echo "  ✓ overwrite backs up dst when content differs"
else failed=$((failed+1)); echo "  ✗ overwrite backs up dst when content differs (backup=$backup, got=$got)" >&2; fi

# Test 6: overwrite refuses symlink destination
echo "target" > "$TMP/symtarget"
ln -s "$TMP/symtarget" "$TMP/dst6-symlink"
err_output=$(deploy_one "git/sample|$TMP/dst6-symlink|overwrite|0644" "$TMP/src" 2>&1) && rc=$? || rc=$?
target_unchanged=$(cat "$TMP/symtarget")
if [[ "$rc" == "2" ]] && [[ "$target_unchanged" == "target" ]] && [[ "$err_output" == *symlink* ]]; then passed=$((passed+1)); echo "  ✓ overwrite refuses symlink with rc=2"
else failed=$((failed+1)); echo "  ✗ overwrite refuses symlink with rc=2 (rc=$rc, target=$target_unchanged)" >&2; fi

# Test 7: managed_block refuses symlink destination
ln -s "$TMP/symtarget" "$TMP/dst7-symlink"
err_output=$(deploy_one "git/sample|$TMP/dst7-symlink|managed_block|0644" "$TMP/src" 2>&1) && rc=$? || rc=$?
target_unchanged=$(cat "$TMP/symtarget")
if [[ "$rc" == "2" ]] && [[ "$target_unchanged" == "target" ]] && [[ "$err_output" == *symlink* ]]; then passed=$((passed+1)); echo "  ✓ managed_block refuses symlink with rc=2"
else failed=$((failed+1)); echo "  ✗ managed_block refuses symlink with rc=2 (rc=$rc, target=$target_unchanged)" >&2; fi

# Test 8: atomic write — no .deploy.tmp.* left dangling on success
echo "first" > "$TMP/dst8"
deploy_one "git/sample|$TMP/dst8|overwrite|0644" "$TMP/src"
leftovers=$(find "$TMP" -maxdepth 1 -name '.deploy.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$leftovers" == "0" ]] && [[ "$(cat "$TMP/dst8")" == "hello" ]]; then passed=$((passed+1)); echo "  ✓ atomic write leaves no temp leftovers on success"
else failed=$((failed+1)); echo "  ✗ atomic write leaves no temp leftovers on success (leftovers=$leftovers)" >&2; fi

# Test 9 (CP4 F-004 regression): symlink-to-matching-content is still refused
# (symlink check must run BEFORE cmp-skip fast path)
echo "hello" > "$TMP/matched-target"
ln -s "$TMP/matched-target" "$TMP/dst9-symlink"
err_output=$(deploy_one "git/sample|$TMP/dst9-symlink|overwrite|0644" "$TMP/src" 2>&1) && rc=$? || rc=$?
target_unchanged=$(readlink "$TMP/dst9-symlink" 2>/dev/null)
if [[ "$rc" == "2" ]] && [[ "$target_unchanged" == "$TMP/matched-target" ]] && [[ "$err_output" == *symlink* ]]; then passed=$((passed+1)); echo "  ✓ F-004 symlink check precedes cmp-skip (refused even when target content matches src)"
else failed=$((failed+1)); echo "  ✗ F-004 symlink check precedes cmp-skip (rc=$rc)" >&2; fi

# Test 10 (CP4 F-005 regression): directory destination is refused in overwrite mode
mkdir -p "$TMP/dst10-dir"
err_output=$(deploy_one "git/sample|$TMP/dst10-dir|overwrite|0644" "$TMP/src" 2>&1) && rc=$? || rc=$?
if [[ "$rc" == "2" ]] && [[ -d "$TMP/dst10-dir" ]] && [[ ! -f "$TMP/dst10-dir" ]] && [[ "$err_output" == *"not a regular file"* ]]; then passed=$((passed+1)); echo "  ✓ F-005 overwrite refuses directory destination"
else failed=$((failed+1)); echo "  ✗ F-005 overwrite refuses directory destination (rc=$rc)" >&2; fi

# Test 11 (CP4 F-005 regression): directory destination is refused in once mode
mkdir -p "$TMP/dst11-dir"
err_output=$(deploy_one "git/sample|$TMP/dst11-dir|once|0644" "$TMP/src" 2>&1) && rc=$? || rc=$?
if [[ "$rc" == "2" ]] && [[ -d "$TMP/dst11-dir" ]] && [[ "$err_output" == *"not a regular file"* ]]; then passed=$((passed+1)); echo "  ✓ F-005 once refuses directory destination"
else failed=$((failed+1)); echo "  ✗ F-005 once refuses directory destination (rc=$rc)" >&2; fi

# Test 12 (CP4 F-005 regression): directory destination is refused in managed_block mode
mkdir -p "$TMP/dst12-dir"
err_output=$(deploy_one "git/sample|$TMP/dst12-dir|managed_block|0644" "$TMP/src" 2>&1) && rc=$? || rc=$?
if [[ "$rc" == "2" ]] && [[ -d "$TMP/dst12-dir" ]] && [[ "$err_output" == *"not a regular file"* ]]; then passed=$((passed+1)); echo "  ✓ F-005 managed_block refuses directory destination"
else failed=$((failed+1)); echo "  ✗ F-005 managed_block refuses directory destination (rc=$rc)" >&2; fi

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
