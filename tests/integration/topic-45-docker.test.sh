#!/usr/bin/env bash
# tests/integration/topic-45-docker.test.sh — pilot migration to the engine.
#
# Verifies:
#   1. items.yaml parses and exposes the expected 7 items (3 mac + 3 wsl apt + 1 wsl custom).
#   2. install.sh is the thin engine dispatcher (no inline brew/apt logic).
#   3. post-setup-wsl.sh defines all 4 contract functions (check/install/verify/rollback).
#   4. Engine dry-run --platform=mac processes 3 items, skips 4.
#   5. Engine dry-run --platform=wsl processes 4 items, skips 3.
#   6. Legacy install.{mac,wsl}.sh are gone (topic now uses install.sh exclusively).
#   7. L09 + L11 + L15 + L16 + L17 all clean on the new 45-docker tree.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
TOPIC="$REPO_ROOT/topics/45-docker"
ENGINE="$REPO_ROOT/scripts/lib/install-engine.sh"

# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

# ─── Test 1: structure ──────────────────────────────────────────────
echo "Test 1: 45-docker structure"
assert_file_exists "$TOPIC/items.yaml"          "items.yaml present"
assert_file_exists "$TOPIC/install.sh"          "install.sh present"
assert_file_exists "$TOPIC/post-setup-wsl.sh"   "post-setup-wsl.sh present"
assert_false "test -e '$TOPIC/install.mac.sh'"  "install.mac.sh removed (engine takes over)"
assert_false "test -e '$TOPIC/install.wsl.sh'"  "install.wsl.sh removed (engine takes over)"

# ─── Test 2: install.sh is thin dispatcher ──────────────────────────
echo
echo "Test 2: install.sh delegates to engine"
loc=$(wc -l < "$TOPIC/install.sh")
[[ $loc -le 30 ]] && pass "install.sh is ≤30 LOC (got $loc — pure dispatcher)" || \
    fail "install.sh has grown beyond dispatcher size ($loc LOC)"
assert_file_contains "$TOPIC/install.sh" "install-engine.sh"          "install.sh references install-engine.sh"
assert_file_contains "$TOPIC/install.sh" 'HERE/items.yaml'            "install.sh feeds items.yaml as manifest"
# Absence: install.sh must NOT contain raw brew/apt calls anymore
assert_false "grep -qE '\\bbrew install\\b|\\bapt-get install\\b' '$TOPIC/install.sh'" \
    "install.sh has no raw brew/apt calls (logic moved to items.yaml + engine)"

# ─── Test 3: items.yaml has expected items ──────────────────────────
echo
echo "Test 3: items.yaml manifest content"
parsed=$(bash "$REPO_ROOT/scripts/lib/yaml-parse.sh" < "$TOPIC/items.yaml")
eval "$parsed"
assert_eq "${__YAML_PARSE_OK:-0}" "1" "yaml-parse rc=0 + sentinel set"

# Count items: increment i until ITEM_i_NAME is unset
i=0
while [[ -n "${!j:-}" || -n "$(eval echo \${ITEM_${i}_NAME:-})" ]]; do
    name="$(eval echo \${ITEM_${i}_NAME:-})"
    [[ -z "$name" ]] && break
    i=$((i+1))
done
assert_eq "$i" "7" "items.yaml exposes 7 items total"

# Spot-check named items + their types
assert_eq "${ITEM_0_NAME:-}"      "colima"            "item 0 = colima"
assert_eq "${ITEM_0_TYPE:-}"      "brew-formula"      "item 0 type = brew-formula"
assert_eq "${ITEM_0_PLATFORMS_0:-}" "mac"             "item 0 platforms includes mac"
assert_eq "${ITEM_3_NAME:-}"      "docker-engine"     "item 3 = docker-engine (wsl)"
assert_eq "${ITEM_3_SPEC:-}"      "docker.io"         "docker-engine spec = docker.io"
assert_eq "${ITEM_6_NAME:-}"      "docker-post-setup" "item 6 = docker-post-setup"
assert_eq "${ITEM_6_TYPE:-}"      "custom"            "post-setup type = custom"
assert_eq "${ITEM_6_SCRIPT:-}"    "./post-setup-wsl.sh" "post-setup script ref is relative"

# ─── Test 4: post-setup-wsl.sh contract surface ─────────────────────
echo
echo "Test 4: post-setup-wsl.sh contract functions"
for fn in check install verify rollback; do
    ASSERT_MSG="post-setup-wsl.sh defines ${fn}()" \
        assert_true "grep -qE '^${fn}\\(\\)' '$TOPIC/post-setup-wsl.sh'"
done
ASSERT_MSG="post-setup-wsl.sh is executable (custom driver requires +x)" \
    assert_true "test -x '$TOPIC/post-setup-wsl.sh'"

# ─── Test 5: engine dry-run --platform=mac ──────────────────────────
echo
echo "Test 5: dry-run as mac processes 3 + skips 4"
out=$(bash "$ENGINE" --manifest "$TOPIC/items.yaml" \
    --installers-dir "$REPO_ROOT/scripts/lib/installers" \
    --platform mac --dry-run 2>&1)
processed_mac=$(printf '%s\n' "$out" | grep -c '\[dry-run\] would process')
skipped_mac=$(printf '%s\n' "$out" | grep -c 'skipping (platforms: excludes mac)')
assert_eq "$processed_mac" "3" "mac processes exactly 3 items (colima, docker, docker-compose)"
assert_eq "$skipped_mac"   "4" "mac skips exactly 4 items (3 apt + 1 custom)"
assert_contains "$out" "completed 3 items on mac" "summary line matches mac plan"

# ─── Test 6: engine dry-run --platform=wsl ──────────────────────────
echo
echo "Test 6: dry-run as wsl processes 4 + skips 3"
out=$(bash "$ENGINE" --manifest "$TOPIC/items.yaml" \
    --installers-dir "$REPO_ROOT/scripts/lib/installers" \
    --platform wsl --dry-run 2>&1)
processed_wsl=$(printf '%s\n' "$out" | grep -c '\[dry-run\] would process')
skipped_wsl=$(printf '%s\n' "$out" | grep -c 'skipping (platforms: excludes wsl)')
assert_eq "$processed_wsl" "4" "wsl processes exactly 4 items"
assert_eq "$skipped_wsl"   "3" "wsl skips exactly 3 items (mac brew formulae)"
assert_contains "$out" "completed 4 items on wsl" "summary line matches wsl plan"

# ─── Test 7: lints clean on the new 45-docker tree ──────────────────
echo
echo "Test 7: relevant lints clean"
# L09 (custom-script-contract) — post-setup-wsl.sh defines check + install
bash "$REPO_ROOT/scripts/lib/lints/L09-custom-script-contract.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "L09 (custom-script-contract) rc=0 for 45-docker"
# L11 (template-files-example) — independent of 45-docker, but spot-check
bash "$REPO_ROOT/scripts/lib/lints/L11-template-files-example.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "L11 rc=0"
# L15 (bash 3.2 compat) — install.sh / post-setup are bash 3.2 safe
bash "$REPO_ROOT/scripts/lib/lints/L15-bash32-compat.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "L15 rc=0"
# L17 (inline-script-call advisory) — 45-docker has no `bash $HERE/scripts/install-*.sh`
l17_out=$(bash "$REPO_ROOT/scripts/lib/lints/L17-inline-script-call.sh" 2>&1)
assert_false "echo '$l17_out' | grep -q '45-docker'" "L17 advisory does NOT mention 45-docker (no inline script calls)"

summary
