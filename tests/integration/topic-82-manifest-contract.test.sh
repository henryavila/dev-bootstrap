#!/usr/bin/env bash
# tests/integration/topic-82-manifest-contract.test.sh
#
# rtk must not ship a manifest `check:` override (that would bypass
# install-rtk.sh's `rtk gain` collision guard).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
MANIFEST="$REPO_ROOT/topics/ai/manifest.yaml"
INSTALL_RTK="$REPO_ROOT/topics/ai/install-rtk.sh"
PARSER="$REPO_ROOT/scripts/lib/yaml-parse.sh"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

assert_file_exists "$MANIFEST" "ai/manifest.yaml exists"
assert_file_exists "$INSTALL_RTK" "install-rtk.sh exists"
assert_file_exists "$PARSER" "yaml-parse.sh exists"

TMP=$(mktemp -d -t topic-82-contract.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
bash "$PARSER" < "$MANIFEST" > "$TMP/parsed.env"
# shellcheck source=/dev/null
source "$TMP/parsed.env"

rtk_bundle=""
n="${BUNDLE_COUNT:-0}"
for i in $(seq 0 $((n - 1))); do
    nv="BUNDLE_${i}_NAME"
    if [[ "${!nv:-}" == "rtk" ]]; then
        rtk_bundle="$i"
        break
    fi
done
assert_ne "$rtk_bundle" "" "rtk bundle found in ai/manifest.yaml"

item_count_var="BUNDLE_${rtk_bundle}_ITEM_COUNT"
assert_eq "${!item_count_var:-}" "1" "rtk bundle has one item"

check_var="BUNDLE_${rtk_bundle}_ITEM_0_CHECK"
assert_eq "${!check_var:-}" "" "F-008 — rtk has no manifest check: (would bypass install-rtk.sh check())"

script_var="BUNDLE_${rtk_bundle}_ITEM_0_SCRIPT"
assert_eq "${!script_var:-}" "./install-rtk.sh" "rtk script points to install-rtk.sh"

type_var="BUNDLE_${rtk_bundle}_ITEM_0_TYPE"
assert_eq "${!type_var:-}" "custom" "rtk type is custom"

for fn in install check verify rollback; do
    ASSERT_MSG="install-rtk.sh defines $fn()" \
        assert_true "grep -qE '^${fn}\\(\\)' '$INSTALL_RTK'"
done

ASSERT_MSG="install-rtk.sh check() uses 'rtk gain' as collision discriminator" \
    assert_true "grep -q 'rtk gain' '$INSTALL_RTK'"

ASSERT_MSG="install() no longer pipes curl to sh from master branch" \
    assert_false "grep -qE 'curl[^|]*master/install\\.sh[[:space:]]*\\|[[:space:]]*sh' '$INSTALL_RTK'"

summary
