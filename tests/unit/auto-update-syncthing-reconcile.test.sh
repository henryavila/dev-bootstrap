#!/usr/bin/env bash
# Unit test for _syncthing_yaml_changed (auto-update.sh, T-002). The motor
# auto-reconciles `mesh syncthing pair` when an identity `mesh update` pulls a
# changed sync/syncthing-mesh.yaml. This proves the pure decision: which diff
# paths count as "the declarative mesh changed" (the pair itself needs the
# daemon and is metal-validated). The `.example` template must NOT trigger it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
AU="$WS/scripts/runners/auto-update.sh"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected [$expected], got [$actual])" >&2; fi
}

# Extract just the pure function so we don't run the script's heavy top-level init.
func_src=$(awk '
    /^_syncthing_yaml_changed\(\)/ { capture=1 }
    capture { print }
    capture && /^}/ { exit }
' "$AU")
[[ -n "$func_src" ]] || { echo "FAIL: could not extract _syncthing_yaml_changed from $AU" >&2; exit 1; }
eval "$func_src"

# changed?  → returns rc 0 (yes) / rc 1 (no); capture as a yes/no string.
changed() { _syncthing_yaml_changed "$1" && echo yes || echo no; }

# ── positives: the real data file, both supported locations ──
assert "canonical sync/ path triggers"        "yes" "$(changed 'sync/syncthing-mesh.yaml')"
assert "legacy claude/sync/ path triggers"    "yes" "$(changed 'claude/sync/syncthing-mesh.yaml')"
assert "detected among many changed files"    "yes" "$(changed $'README.md\nsync/syncthing-mesh.yaml\nbin/x')"

# ── negatives ──
assert "shipped .example does NOT trigger"    "no"  "$(changed 'sync/syncthing-mesh.yaml.example')"
assert "unrelated yaml does NOT trigger"      "no"  "$(changed 'sync/other.yaml')"
assert "unrelated file does NOT trigger"      "no"  "$(changed 'README.md')"
assert "empty diff does NOT trigger"          "no"  "$(changed '')"
# a path that merely contains the name mid-segment must not match (anchored)
assert "non-suffix match does NOT trigger"    "no"  "$(changed 'docs/sync/syncthing-mesh.yaml.bak')"

echo
echo "auto-update-syncthing-reconcile: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
