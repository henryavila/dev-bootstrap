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

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
