#!/usr/bin/env bash
# Unit tests for managed-block.sh — splice between mesh-managed markers.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
LIB="$WS/scripts/lib/managed-block.sh"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected: '$expected', got: '$actual')" >&2; fi
}

. "$LIB"

# Test 1: inject block into empty file
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
touch "$TMP/target"
managed_block_apply "$TMP/target" "ssh-keys" <<'EOF'
ssh-rsa AAAA... user@host
EOF
expected="# >>> BEGIN mesh-managed: ssh-keys >>>
ssh-rsa AAAA... user@host
# <<< END mesh-managed: ssh-keys <<<"
actual=$(cat "$TMP/target")
assert "inject into empty" "$expected" "$actual"

# Test 2: re-apply with same content is idempotent (file unchanged)
hash_before=$(shasum "$TMP/target" | awk '{print $1}')
managed_block_apply "$TMP/target" "ssh-keys" <<'EOF'
ssh-rsa AAAA... user@host
EOF
hash_after=$(shasum "$TMP/target" | awk '{print $1}')
assert "re-apply idempotent" "$hash_before" "$hash_after"

# Test 3: case-insensitive marker match (mesh-managed: vs MESH-MANAGED:)
echo "# >>> BEGIN MESH-MANAGED: case-test >>>
old content
# <<< END MESH-MANAGED: case-test <<<" > "$TMP/case-target"
managed_block_apply "$TMP/case-target" "case-test" <<'EOF'
new content
EOF
got=$(grep -c "new content" "$TMP/case-target")
assert "case-insensitive match: replaced" "1" "$got"

# Test 4: old dotfiles-managed marker also matched (case-insensitive, L16 / bug-2026-04-23)
echo "# >>> BEGIN dotfiles-managed: legacy >>>
should-be-replaced
# <<< END dotfiles-managed: legacy <<<" > "$TMP/legacy-target"
managed_block_apply "$TMP/legacy-target" "legacy" <<'EOF'
fresh
PAD
EOF
got=$(grep -c 'mesh-managed: legacy' "$TMP/legacy-target")
assert "legacy marker upgraded to mesh-managed" "2" "$got"

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
