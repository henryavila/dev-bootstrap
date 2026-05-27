#!/usr/bin/env bash
# tests/unit/uninstall-engine.test.sh
# Verify uninstall-engine.sh dispatch and argument handling.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/tests/lib/assert.sh"

echo
echo "═══ uninstall-engine ═══"

UNINSTALL_ENGINE="$ROOT/scripts/lib/uninstall-engine.sh"

# 1. File exists and is syntactically valid
assert_file_exists "$UNINSTALL_ENGINE" "uninstall-engine.sh exists"
bash -n "$UNINSTALL_ENGINE" && pass "syntax check passes" || fail "syntax error"

# 2. Requires --items
output=$(bash "$UNINSTALL_ENGINE" --manifest /dev/null 2>&1 || true)
assert_contains "$output" "missing --items" "requires --items flag"

# 3. Sources uninstall-handlers.sh
assert_pattern_present "$UNINSTALL_ENGINE" 'uninstall-handlers.sh' \
    "sources shared handlers"

# 4. Dry-run mode
FIXTURES="$HERE/fixtures/uninstall-test"
mkdir -p "$FIXTURES"

cat > "$FIXTURES/items.yaml" <<'YAML'
- name: test-brew
  type: brew-formula
  spec: fake-pkg
  platforms: [mac]

- name: test-custom
  type: custom
  script: "./test-script.sh"
  platforms: [mac]
YAML

output=$(bash "$UNINSTALL_ENGINE" \
    --manifest "$FIXTURES/items.yaml" \
    --items=test-brew,test-custom \
    --dry-run \
    --platform mac 2>&1 || true)

assert_contains "$output" "dry-run" "dry-run output present"
assert_contains "$output" "test-brew" "test-brew mentioned in dry-run"
assert_contains "$output" "test-custom" "test-custom mentioned in dry-run"

# 5. Platform filter
output=$(bash "$UNINSTALL_ENGINE" \
    --manifest "$FIXTURES/items.yaml" \
    --items=test-brew \
    --dry-run \
    --platform wsl 2>&1 || true)

if echo "$output" | grep -q "dry-run.*test-brew"; then
    fail "mac-only item should be skipped on wsl"
else
    pass "platform filter skips mac-only items on wsl"
fi

# 6. D-B3 invariant: install-engine.sh has no uninstall logic
if grep -v '^#' "$ROOT/scripts/lib/install-engine.sh" | grep -v 'items' | grep -qi 'uninstall'; then
    fail "install-engine.sh contains uninstall logic (D-B3 violation)"
else
    pass "D-B3: install-engine.sh has no uninstall logic"
fi

rm -rf "$FIXTURES"

summary
