#!/usr/bin/env bash
# Unit tests for C1 doctor checks: check_launchd_volume_paths + check_composer_phar.
# Drives the full doctor.sh via --json under fixture env so we exercise the
# end-to-end behavior (function logic + counter accumulation + JSON emission).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
DOCTOR="$WS/scripts/runners/doctor.sh"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected: '$expected', got: '$actual')" >&2; fi
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Common fixture env: skip mappings (no install.sh) and marker check (empty list).
# Each test layers DOCTOR_LAUNCHD_DIR and PATH on top.
run_doctor_field() {
    local field="$1"
    shift
    local out
    out=$(MESH_IDENTITY_DIR="$TMP/no-identity" \
          DOCTOR_MARKER_FILES="$TMP/no-such-marker-file" \
          "$@" \
          bash "$DOCTOR" --json 2>/dev/null || true)
    # Minimal JSON extraction: grep -oE the field number.
    echo "$out" | grep -oE "\"${field}\":[0-9]+" | head -1 | cut -d: -f2
}

# ─── check_launchd_volume_paths ────────────────────────────────────

if [[ "$(uname -s)" == "Darwin" ]]; then
    # Test 1: plist with /Volumes/ StandardErrorPath → counted
    mkdir -p "$TMP/launchd-bad"
    cat > "$TMP/launchd-bad/homebrew.mxcl.fake-service.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>StandardErrorPath</key>
    <string>/Volumes/External/log/fake.err</string>
</dict>
</plist>
EOF
    n=$(DOCTOR_LAUNCHD_DIR="$TMP/launchd-bad" run_doctor_field launchd_phantom)
    assert "launchd plist with /Volumes/ in Standard*Path is counted" "1" "$n"

    # Test 2: plist with safe StandardOutPath → not counted
    mkdir -p "$TMP/launchd-ok"
    cat > "$TMP/launchd-ok/homebrew.mxcl.fake-service.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>StandardOutPath</key>
    <string>/var/log/homebrew/fake.out</string>
</dict>
</plist>
EOF
    n=$(DOCTOR_LAUNCHD_DIR="$TMP/launchd-ok" run_doctor_field launchd_phantom)
    assert "launchd plist with /var/log path is not counted" "0" "$n"

    # Test 3: launchd dir missing → silent return 0
    n=$(DOCTOR_LAUNCHD_DIR="$TMP/launchd-missing" run_doctor_field launchd_phantom)
    assert "missing launchd dir → 0 silent" "0" "$n"

    # Test 4: non-homebrew.mxcl plist with /Volumes/ → ignored (scope-narrow)
    mkdir -p "$TMP/launchd-other"
    cat > "$TMP/launchd-other/com.example.foo.plist" <<'EOF'
<?xml version="1.0"?>
<plist><dict>
    <key>StandardErrorPath</key>
    <string>/Volumes/Foo/x</string>
</dict></plist>
EOF
    n=$(DOCTOR_LAUNCHD_DIR="$TMP/launchd-other" run_doctor_field launchd_phantom)
    assert "non-homebrew.mxcl plist is ignored" "0" "$n"
    # Test 4b (CP4 D-F-008 regression): plist with comments / blank lines
    # between <key> and <string> — the old grep -A1 would miss this; plutil
    # parses semantically and still counts it.
    mkdir -p "$TMP/launchd-formatted"
    cat > "$TMP/launchd-formatted/homebrew.mxcl.fake-service.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <!-- inline comment between key and value would break grep -A1 -->
    <key>StandardErrorPath</key>

    <string>/Volumes/External/log/fake.err</string>
</dict>
</plist>
EOF
    n=$(DOCTOR_LAUNCHD_DIR="$TMP/launchd-formatted" run_doctor_field launchd_phantom)
    assert "D-F-008 formatted plist (comment + blank between key/value) is counted" "1" "$n"

    # Test 4c (CP4 D-F-008 regression): plist where both StandardErrorPath
    # AND StandardOutPath point at /Volumes/ — must count the plist ONCE,
    # not twice. The `break` after the first key-match enforces this.
    mkdir -p "$TMP/launchd-both"
    cat > "$TMP/launchd-both/homebrew.mxcl.fake-service.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>StandardErrorPath</key>
    <string>/Volumes/External/log/fake.err</string>
    <key>StandardOutPath</key>
    <string>/Volumes/External/log/fake.out</string>
</dict>
</plist>
EOF
    n=$(DOCTOR_LAUNCHD_DIR="$TMP/launchd-both" run_doctor_field launchd_phantom)
    assert "D-F-008 plist with both phantom paths is counted once" "1" "$n"
else
    # On Linux/WSL: function returns 0 unconditionally (uname guard).
    n=$(run_doctor_field launchd_phantom)
    assert "non-Darwin → launchd check no-op" "0" "$n"
fi

# ─── check_composer_phar ───────────────────────────────────────────

# Shim composer factory: writes a script at $1 that prints $2 to stderr and
# exits $3. PATH must include the parent dir.
make_composer_shim() {
    local path="$1" stderr="$2" rc="$3"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<EOF
#!/usr/bin/env bash
echo "$stderr" >&2
exit $rc
EOF
    chmod +x "$path"
}

# Test 5: composer succeeds → not counted
make_composer_shim "$TMP/bin-ok/composer" "Composer 2.7.0" 0
n=$(PATH="$TMP/bin-ok:$PATH" run_doctor_field composer_phar)
assert "healthy composer → composer_phar 0" "0" "$n"

# Test 6: composer fails with SHA512 broken-signature string → counted
make_composer_shim "$TMP/bin-broken/composer" \
    "PharException: SHA512 signature could not be verified: broken signature" 1
n=$(PATH="$TMP/bin-broken:$PATH" run_doctor_field composer_phar)
assert "broken-signature composer → composer_phar 1" "1" "$n"

# Test 7: composer fails with unrelated error → not counted
make_composer_shim "$TMP/bin-otherfail/composer" "Some unrelated error" 1
n=$(PATH="$TMP/bin-otherfail:$PATH" run_doctor_field composer_phar)
assert "unrelated composer failure → composer_phar 0" "0" "$n"

# Test 8: composer absent from PATH → no-op
# Use a minimal PATH (just /usr/bin /bin) and assume composer isn't there.
# Skip if a system composer is found.
if ! PATH=/usr/bin:/bin command -v composer >/dev/null 2>&1; then
    n=$(PATH=/usr/bin:/bin run_doctor_field composer_phar)
    assert "composer absent → composer_phar 0" "0" "$n"
fi

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
