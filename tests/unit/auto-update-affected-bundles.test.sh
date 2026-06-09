#!/usr/bin/env bash
# Unit test for _affected_selected_bundles (auto-update.sh incremental
# re-apply). Manifest v2 dropped the topics/NN- prefix, so the old
# `grep -oE '^topics/[0-9]+-...'` detection matched nothing and per-topic
# re-apply silently did nothing. This proves the v2 detection: changed
# `topics/<name>/...` paths → the still-SELECTED bundles of those topics.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
AU="$WS/scripts/runners/auto-update.sh"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name" >&2; echo "    expected: [$expected]" >&2; echo "    got:      [$actual]" >&2; fi
}

# Extract just the pure function so we don't run the script's heavy top-level init.
func_src=$(awk '
    /^_affected_selected_bundles\(\)/ { capture=1 }
    capture { print }
    capture && /^}/ { exit }
' "$AU")
[[ -n "$func_src" ]] || { echo "FAIL: could not extract _affected_selected_bundles from $AU" >&2; exit 1; }
eval "$func_src"

SEL=$'foundation/base\nweb/valet\ndatabases/mysql\nai/claude-code\n# a comment\ngit/config'

# 1) A changed file under a selected topic → that topic's selected bundles.
out="$(_affected_selected_bundles $'topics/web/templates/nginx.conf\nREADME.md' "$SEL")"
assert "web change → web/valet" "web/valet" "$out"

# 2) Multiple changed topics → union of their selected bundles (sel order preserved).
out="$(_affected_selected_bundles $'topics/web/scripts/x.sh\ntopics/databases/manifest.yaml' "$SEL")"
assert "web+databases change" $'web/valet\ndatabases/mysql' "$out"

# 3) A topic with NO selected bundle → empty (nothing to re-apply).
out="$(_affected_selected_bundles 'topics/syncthing/manifest.yaml' "$SEL")"
assert "unselected topic → empty" "" "$out"

# 4) The v2 regression case: a real topic dir (no NN- prefix) is detected.
#    The OLD code's '^topics/[0-9]+-' would have returned empty here.
out="$(_affected_selected_bundles 'topics/ai/install-claude.sh' "$SEL")"
assert "ai change → ai/claude-code (no NN- prefix needed)" "ai/claude-code" "$out"

# 5) A legacy NN-prefixed path must NOT match a v2 topic dir.
out="$(_affected_selected_bundles 'topics/60-web-stack/install.sh' "$SEL")"
assert "legacy NN- path → empty (topic '60-web-stack' not selected)" "" "$out"

# 6) Non-topic diff paths → empty.
out="$(_affected_selected_bundles $'scripts/lib/install-engine.sh\nbin/mesh' "$SEL")"
assert "non-topic changes → empty" "" "$out"

# 7) Comments / blank lines in selections.list are ignored.
out="$(_affected_selected_bundles 'topics/git/config.x' "$SEL")"
assert "git change → git/config (comment line skipped)" "git/config" "$out"

echo
echo "passed=$passed failed=$failed"
[[ $failed -eq 0 ]]
