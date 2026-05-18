#!/usr/bin/env bash
# Unit tests for scripts/lib/install-engine.sh — platforms: filter (spec §C17).
# Verifies: items run only when current platform is in their `platforms:` list,
# empty/missing `platforms:` means run-on-all, --platform overrides $MESH_OS.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
ENGINE="$WS/scripts/lib/install-engine.sh"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected: $expected, got: $actual)" >&2; fi
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Fixture manifest: 4 items spread across platforms.
cat > "$TMP/items.yaml" <<'YAML'
- name: only-mac
  type: noop
  spec: only-mac
  platforms: [mac]

- name: only-wsl
  type: noop
  spec: only-wsl
  platforms: [wsl]

- name: mac-and-wsl
  type: noop
  spec: mac-and-wsl
  platforms: [mac, wsl]

- name: any-platform
  type: noop
  spec: any-platform
YAML

# Mock noop driver: always passes check (so engine never tries to install).
# Engine only logs "$name: already present, skipping" — we grep that.
mkdir -p "$TMP/installers"
cat > "$TMP/installers/noop.sh" <<'SH'
noop_check()   { return 0; }
noop_install() { :; }
noop_verify()  { return 0; }
SH

# Test 1: --platform=mac processes only-mac + mac-and-wsl + any-platform; skips only-wsl
out=$(bash "$ENGINE" --manifest "$TMP/items.yaml" --installers-dir "$TMP/installers" \
    --platform mac 2>&1 || true)
echo "$out" | grep -q 'only-mac: already present'    && pass1=yes || pass1=no
echo "$out" | grep -q 'mac-and-wsl: already present' && pass2=yes || pass2=no
echo "$out" | grep -q 'any-platform: already present' && pass3=yes || pass3=no
echo "$out" | grep -q 'only-wsl: skipping (platforms: excludes mac)' && skip1=yes || skip1=no
assert "--platform=mac processes only-mac"        "yes" "$pass1"
assert "--platform=mac processes mac-and-wsl"     "yes" "$pass2"
assert "--platform=mac processes any-platform"    "yes" "$pass3"
assert "--platform=mac skips only-wsl"            "yes" "$skip1"

# Test 2: --platform=wsl processes only-wsl + mac-and-wsl + any-platform; skips only-mac
out=$(bash "$ENGINE" --manifest "$TMP/items.yaml" --installers-dir "$TMP/installers" \
    --platform wsl 2>&1 || true)
echo "$out" | grep -q 'only-wsl: already present'    && pass1=yes || pass1=no
echo "$out" | grep -q 'mac-and-wsl: already present' && pass2=yes || pass2=no
echo "$out" | grep -q 'only-mac: skipping (platforms: excludes wsl)' && skip1=yes || skip1=no
assert "--platform=wsl processes only-wsl"        "yes" "$pass1"
assert "--platform=wsl processes mac-and-wsl"     "yes" "$pass2"
assert "--platform=wsl skips only-mac"            "yes" "$skip1"

# Test 3: --platform=linux processes only any-platform; skips the 3 mac/wsl-tagged
out=$(bash "$ENGINE" --manifest "$TMP/items.yaml" --installers-dir "$TMP/installers" \
    --platform linux 2>&1 || true)
echo "$out" | grep -q 'any-platform: already present' && pass1=yes || pass1=no
echo "$out" | grep -q 'only-mac: skipping (platforms: excludes linux)'    && skip1=yes || skip1=no
echo "$out" | grep -q 'only-wsl: skipping (platforms: excludes linux)'    && skip2=yes || skip2=no
echo "$out" | grep -q 'mac-and-wsl: skipping (platforms: excludes linux)' && skip3=yes || skip3=no
assert "--platform=linux processes any-platform"  "yes" "$pass1"
assert "--platform=linux skips only-mac"          "yes" "$skip1"
assert "--platform=linux skips only-wsl"          "yes" "$skip2"
assert "--platform=linux skips mac-and-wsl"       "yes" "$skip3"

# Test 4: $MESH_OS env var works when --platform absent
out=$(MESH_OS=wsl bash "$ENGINE" --manifest "$TMP/items.yaml" --installers-dir "$TMP/installers" 2>&1 || true)
echo "$out" | grep -q 'only-wsl: already present' && pass1=yes || pass1=no
echo "$out" | grep -q 'only-mac: skipping (platforms: excludes wsl)' && skip1=yes || skip1=no
assert "MESH_OS=wsl env resolves current platform"  "yes" "$pass1"
assert "MESH_OS=wsl skips mac-only item"            "yes" "$skip1"

# Test 5: --platform overrides $MESH_OS
out=$(MESH_OS=wsl bash "$ENGINE" --manifest "$TMP/items.yaml" --installers-dir "$TMP/installers" \
    --platform mac 2>&1 || true)
echo "$out" | grep -q 'only-mac: already present' && pass1=yes || pass1=no
echo "$out" | grep -q 'only-wsl: skipping (platforms: excludes mac)' && skip1=yes || skip1=no
assert "--platform overrides MESH_OS=wsl"           "yes" "$pass1"
assert "--platform=mac skips wsl item even with MESH_OS=wsl" "yes" "$skip1"

# Test 6: summary line includes platform + skip count
out=$(bash "$ENGINE" --manifest "$TMP/items.yaml" --installers-dir "$TMP/installers" \
    --platform mac 2>&1 || true)
echo "$out" | grep -qE 'completed 3 items on mac \(1 skipped' && got=yes || got=no
assert "summary names platform + skip count"      "yes" "$got"

# Test 7: empty platforms list (no `platforms:` field at all) runs on every platform
cat > "$TMP/items-noplat.yaml" <<'YAML'
- name: universal
  type: noop
  spec: universal
YAML
for plat in mac wsl linux freebsd unknown; do
    out=$(bash "$ENGINE" --manifest "$TMP/items-noplat.yaml" --installers-dir "$TMP/installers" \
        --platform "$plat" 2>&1 || true)
    echo "$out" | grep -q 'universal: already present' && got=yes || got=no
    assert "platforms: absent ⇒ runs on $plat"        "yes" "$got"
done

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
