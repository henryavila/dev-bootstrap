#!/usr/bin/env bash
# tests/integration/topic-82-manifest-contract.test.sh
#
# CP4 chunk A3 finding F-008 regression: items.yaml's `check:` field is
# now honored by the engine (per A2-F-007 fix at commit 92e3a9a) as a
# pre-install skip override. For `type: custom` items, manifest_check
# REPLACES the topic-shipped check() function — bypassing collision /
# version / ownership guards.
#
# The rtk entry had `check: "command -v rtk"` which silently bypassed
# install-rtk.sh's `rtk gain` collision guard against reachingforthejack/
# rtk (Rust Type Kit). This test asserts the manifest correctly has NO
# `check:` field for the rtk entry so engine falls through to
# custom_check → install-rtk.sh check().
#
# Also asserts the parsed items.yaml shape for all 3 entries (presence
# of required fields per engine contract).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
MANIFEST="$REPO_ROOT/topics/82-ai-tools/items.yaml"
INSTALL_RTK="$REPO_ROOT/topics/82-ai-tools/install-rtk.sh"
PARSER="$REPO_ROOT/scripts/lib/yaml-parse.sh"

# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

assert_file_exists "$MANIFEST" "items.yaml exists"
assert_file_exists "$INSTALL_RTK" "install-rtk.sh exists"
assert_file_exists "$PARSER" "yaml-parse.sh exists"

# ─── Test 1: rtk entry has NO manifest check: (F-008 regression) ─
# Parse items.yaml via the engine's own parser to avoid hand-grepping.
TMP=$(mktemp -d -t topic-82-contract.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
bash "$PARSER" < "$MANIFEST" > "$TMP/parsed.env"
# shellcheck source=/dev/null
source "$TMP/parsed.env"

# 3 items expected
assert_eq "$ITEM_COUNT" "3" "Test 1a: items.yaml parses to 3 items"

# Find rtk's index dynamically (parser orders by appearance — rtk is item 3)
rtk_idx=""
for i in $(seq 0 $((ITEM_COUNT - 1))); do
    nm_var="ITEM_${i}_NAME"
    if [[ "${!nm_var}" == "rtk" ]]; then
        rtk_idx="$i"
        break
    fi
done
assert_ne "$rtk_idx" "" "Test 1b: rtk entry found in manifest"

rtk_check_var="ITEM_${rtk_idx}_CHECK"
# The engine reads "${!check_var:-}" — if check: is absent, the var is
# unset (or empty). Both forms must be treated as "no manifest check".
rtk_check_value="${!rtk_check_var:-}"
assert_eq "$rtk_check_value" "" "Test 1c: F-008 — rtk has no manifest check: (would bypass install-rtk.sh check())"

# ─── Test 2: rtk script is the relative path ./install-rtk.sh ───
rtk_script_var="ITEM_${rtk_idx}_SCRIPT"
assert_eq "${!rtk_script_var:-}" "./install-rtk.sh" \
    "Test 2: rtk script: field points to install-rtk.sh"

rtk_type_var="ITEM_${rtk_idx}_TYPE"
assert_eq "${!rtk_type_var:-}" "custom" \
    "Test 2b: rtk type is custom"

# ─── Test 3: install-rtk.sh defines the full custom contract ────
# Engine's custom driver requires install + check + verify + rollback
# (A2-F-007 + A2-F-008 fix made the engine refuse incomplete contracts).
for fn in install check verify rollback; do
    ASSERT_MSG="Test 3: install-rtk.sh defines $fn()" \
        assert_true grep -qE "^${fn}\\(\\)" "$INSTALL_RTK"
done

# ─── Test 4: install-rtk.sh check() includes the collision guard ──
# The reason F-008 matters: install-rtk.sh check() asks for `rtk gain`
# which only the Rust Token Killer responds to (Rust Type Kit does not).
ASSERT_MSG="Test 4: install-rtk.sh check() uses 'rtk gain' as collision discriminator" \
    assert_true grep -q "rtk gain" "$INSTALL_RTK"

# ─── Tests 5-8 (CP4 A3-F-007): release-based install with sha256 verify ──
# Replaces the previous `curl raw.githubusercontent.com/.../master/install.sh
# | sh` (mutable URL, no integrity check) with a release-pinned fetch +
# checksums.txt verification.

ASSERT_MSG="Test 5: A3-F-007 — install() no longer pipes curl to sh from master branch" \
    assert_false grep -qE 'curl[^|]*master/install\.sh[[:space:]]*\|[[:space:]]*sh' "$INSTALL_RTK"

ASSERT_MSG="Test 6: A3-F-007 — install fetches checksums.txt from immutable release URL" \
    assert_true grep -q "releases/download/.*checksums.txt" "$INSTALL_RTK"

ASSERT_MSG="Test 7: A3-F-007 — install verifies sha256 mismatch before extracting" \
    assert_true grep -q "sha256 mismatch" "$INSTALL_RTK"

ASSERT_MSG="Test 8: A3-F-007 — install guards against archive path traversal (CWE-22)" \
    assert_true grep -qE '\\\.\\\.\(/\|\$\)' "$INSTALL_RTK"

# ─── Tests 9-11 (CP4 A3-F-009): provenance-tracked rollback ─────────
# rollback() must read recorded install path + sha256 and refuse to delete
# a binary whose hash no longer matches (could be another vendor's rtk).

ASSERT_MSG="Test 9: A3-F-009 — install() records rtk install path + sha256 in state file" \
    assert_true grep -qE 'RTK_STATE_FILE.*rtk-installed\.env' "$INSTALL_RTK"

ASSERT_MSG="Test 10: A3-F-009 — rollback() no longer deletes whichever rtk command -v resolves" \
    assert_false grep -qE 'rm[[:space:]]+-f[[:space:]]+"\$\(command -v rtk' "$INSTALL_RTK"

ASSERT_MSG="Test 11: A3-F-009 — rollback() refuses delete when recorded sha256 differs" \
    assert_true grep -q "refusing to delete" "$INSTALL_RTK"

summary
