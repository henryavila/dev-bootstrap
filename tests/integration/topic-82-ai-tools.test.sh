#!/usr/bin/env bash
# Integration test for topic 82-ai-tools.
# Mocks the 3 drivers (npm-global, npx, custom) so test runs hermetically.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
ENGINE="$WS/scripts/lib/install-engine.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/installers"

# Mock npm-global
cat > "$TMP/installers/npm-global.sh" <<'SH'
npm_global_check()   { test -f "$STATE/mdprobe.installed"; }
npm_global_install() { touch "$STATE/mdprobe.installed"; }
SH

# Mock npx (installs, then check passes by detecting the sentinel file)
cat > "$TMP/installers/npx.sh" <<'SH'
npx_check()   { test -f "$STATE/atomic-skills.installed"; }
npx_install() { touch "$STATE/atomic-skills.installed"; }
SH

# Mock custom (sources script and calls its install function)
cat > "$TMP/installers/custom.sh" <<'SH'
custom_check()   { local s="$1"; ( . "$s"; declare -f check >/dev/null && check ); }
custom_install() { local s="$1"; ( . "$s"; install ); }
custom_verify()  { local s="$1"; ( . "$s"; declare -f verify >/dev/null && verify || ( . "$s"; declare -f check >/dev/null && check ) ); }
SH

# Mocked rtk script (replaces actual curl/install call with file touch)
cat > "$TMP/install-rtk-mocked.sh" <<'SH'
check()   { test -f "$STATE/rtk.installed"; }
install() { touch "$STATE/rtk.installed"; }
verify()  { check; }
SH
chmod +x "$TMP/install-rtk-mocked.sh"

# items.yaml — points custom script at the absolute mock path
cat > "$TMP/items.yaml" <<YAML
- name: mdprobe
  type: npm-global
  spec: "@henryavila/mdprobe"

- name: atomic-skills
  type: npx
  spec: "@henryavila/atomic-skills@1.7.0"

- name: rtk
  type: custom
  script: "$TMP/install-rtk-mocked.sh"
YAML

STATE=$TMP/state
mkdir -p "$STATE"
export STATE

bash "$ENGINE" \
    --manifest "$TMP/items.yaml" \
    --installers-dir "$TMP/installers"

# Verify all 3 files written (proving all 3 dispatch paths fire correctly)
passed=0; failed=0
for tool in mdprobe atomic-skills rtk; do
    if [[ -f "$STATE/${tool}.installed" ]]; then passed=$((passed+1)); echo "  ✓ $tool installed"
    else failed=$((failed+1)); echo "  ✗ $tool not installed" >&2; fi
done

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
