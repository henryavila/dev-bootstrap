#!/usr/bin/env bash
# tests/unit/install-engine-items-filter.test.sh
# Verify that --items= filter limits which items from the manifest are processed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/tests/lib/assert.sh"

echo
echo "═══ install-engine --items= filter ═══"

FIXTURES="$HERE/fixtures/items-filter"
mkdir -p "$FIXTURES"

# Create a test manifest
cat > "$FIXTURES/items.yaml" <<'YAML'
- name: alpha
  type: brew-formula
  spec: alpha-pkg
  platforms: [mac]

- name: beta
  type: brew-formula
  spec: beta-pkg
  platforms: [mac]

- name: gamma
  type: brew-formula
  spec: gamma-pkg
  platforms: [mac]
YAML

# --items=alpha should only process alpha, skip beta and gamma
output=$(bash "$ROOT/scripts/lib/install-engine.sh" \
    --manifest "$FIXTURES/items.yaml" \
    --items=alpha \
    --dry-run \
    --platform mac 2>&1 || true)

assert_contains "$output" "alpha" "alpha is processed with --items=alpha"

# beta and gamma should NOT appear as processed items
if echo "$output" | grep -q "Checking.*beta"; then
    fail "beta should be skipped with --items=alpha"
else
    pass "beta is skipped with --items=alpha"
fi

if echo "$output" | grep -q "Checking.*gamma"; then
    fail "gamma should be skipped with --items=alpha"
else
    pass "gamma is skipped with --items=alpha"
fi

# --items=alpha,gamma should process both, skip beta
output2=$(bash "$ROOT/scripts/lib/install-engine.sh" \
    --manifest "$FIXTURES/items.yaml" \
    --items=alpha,gamma \
    --dry-run \
    --platform mac 2>&1 || true)

if echo "$output2" | grep -q "Checking.*beta"; then
    fail "beta should be skipped with --items=alpha,gamma"
else
    pass "beta is skipped with --items=alpha,gamma"
fi

# Without --items, all items should be processed
output3=$(bash "$ROOT/scripts/lib/install-engine.sh" \
    --manifest "$FIXTURES/items.yaml" \
    --dry-run \
    --platform mac 2>&1 || true)

# All three should appear in output without filter
assert_contains "$output3" "alpha" "alpha processed without filter"
assert_contains "$output3" "beta"  "beta processed without filter"
assert_contains "$output3" "gamma" "gamma processed without filter"

rm -rf "$FIXTURES"

summary
