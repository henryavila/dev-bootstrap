#!/usr/bin/env bash
# tests/integration/external-brew-mount-heal.test.sh
#
# Covers scripts/lib/external-brew-mount.sh + the heal runner + the doctor
# command wiring for the macOS external-brew mount-disambiguation failure
# (incident 2026-05-02; recurred 2026-06-16 after a macOS update regenerated
# the daemon plists).
#
# Two layers:
#   (1) FUNCTIONAL — ebm_detect against a fully stubbed diskutil + a temp
#       /Volumes, proving the canonical volume name is DERIVED (never
#       hardcoded): the same logic resolves "External", "WD Passport", etc.
#       Gated on `plutil` (the lib's plist parser; macOS-bundled).
#   (2) STATIC — grep-asserts the generic-by-construction invariants the user
#       required: macOS-gated, external-only, no hardcoded disk name, rm only
#       behind the phantom-safety guard, base-system tools only.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

LIB="$ROOT/scripts/lib/external-brew-mount.sh"
RUNNER="$ROOT/scripts/runners/heal-external-brew-mount.sh"
DOCTOR_MODULE="$ROOT/scripts/commands/doctor.sh"

assert_pattern_present() {
    local file="$1" pattern="$2" msg="$3"
    if grep -qE "$pattern" "$file" 2>/dev/null; then pass "$msg"
    else fail "$msg (pattern '$pattern' not found in $file)"; fi
}
assert_pattern_absent() {
    local file="$1" pattern="$2" msg="$3"
    if ! grep -qE "$pattern" "$file" 2>/dev/null; then pass "$msg"
    else fail "$msg (anti-pattern '$pattern' found in $file)"; fi
}

# ── A diskutil stub: matches exactly one mount (STUB_MNT) and emits a plist
#    with a configurable VolumeName/DeviceIdentifier; rc1 for anything else
#    (so plain dirs read as "not a mounted volume", i.e. phantoms). ───────────
make_diskutil_stub() {
    local path="$1"
    cat > "$path" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "info" && "$2" == "-plist" ]] || exit 1
mnt="$3"
[[ "$mnt" == "${STUB_MNT:-}" ]] || exit 1
cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>VolumeName</key><string>${STUB_NAME:-}</string>
<key>DeviceIdentifier</key><string>${STUB_DEV:-}</string>
<key>MountPoint</key><string>${mnt}</string>
</dict></plist>
XML
STUB
    chmod +x "$path"
}

echo
echo "═══ external-brew-mount — FUNCTIONAL (stubbed diskutil) ═══"

if ! command -v plutil >/dev/null 2>&1; then
    pass "functional detection — SKIPPED (no plutil; the lib is macOS-only by design)"
else
    TMP="$(mktemp -d -t ebm_test.XXXXXX)"
    trap 'rm -rf "$TMP"' EXIT
    STUB="$TMP/diskutil-stub"; make_diskutil_stub "$STUB"

    # Common injection: force-supported, stubbed diskutil, temp /Volumes.
    export EBM_FORCE_SUPPORTED=1 EBM_DISKUTIL="$STUB" EBM_NO_SUDO=1
    # shellcheck source=../../scripts/lib/external-brew-mount.sh
    . "$LIB"

    # ── Scenario 1: disambiguated "External 1" with a phantom at "External" ──
    mkdir -p "$TMP/Volumes/External 1/homebrew"
    mkdir -p "$TMP/Volumes/External/homebrew/var/log"
    : > "$TMP/Volumes/External/homebrew/var/log/php-fpm.log"
    export EBM_VOLUMES_DIR="$TMP/Volumes"
    export EBM_BREW_PREFIX_OVERRIDE="$TMP/Volumes/External 1/homebrew"
    export STUB_MNT="$TMP/Volumes/External 1" STUB_NAME="External" STUB_DEV="disk99s1"

    if ebm_detect; then pass "ebm_detect — collision detected (External 1 / phantom External)"
    else fail "ebm_detect — should detect the External-1 collision"; fi
    assert_eq "$EBM_VOLUME_NAME"   "External"                       "derives VolumeName from diskutil (not hardcoded)"
    assert_eq "$EBM_CANONICAL_MNT" "$TMP/Volumes/External"          "canonical mount = /Volumes/<derived name>"
    assert_eq "$EBM_ACTUAL_MNT"    "$TMP/Volumes/External 1"        "actual mount captured (with space)"
    assert_eq "$EBM_PHANTOM"       "$TMP/Volumes/External"          "phantom path identified at canonical"
    assert_eq "$EBM_DEVICE"        "disk99s1"                       "device id captured for remount"

    # ── Scenario 2: a DIFFERENT, space-containing name proves non-hardcoding ─
    mkdir -p "$TMP/Volumes/WD Passport 1/homebrew"
    mkdir -p "$TMP/Volumes/WD Passport"
    export EBM_BREW_PREFIX_OVERRIDE="$TMP/Volumes/WD Passport 1/homebrew"
    export STUB_MNT="$TMP/Volumes/WD Passport 1" STUB_NAME="WD Passport" STUB_DEV="disk42s2"
    if ebm_detect; then pass "ebm_detect — collision detected for an arbitrarily-named disk"
    else fail "ebm_detect — should detect the 'WD Passport 1' collision"; fi
    assert_eq "$EBM_VOLUME_NAME"   "WD Passport"                    "derives an arbitrary name with a space"
    assert_eq "$EBM_CANONICAL_MNT" "$TMP/Volumes/WD Passport"       "canonical mount for arbitrary name"

    # ── Scenario 3: already at canonical → no collision ─────────────────────
    export EBM_BREW_PREFIX_OVERRIDE="$TMP/Volumes/External/homebrew"
    export STUB_MNT="$TMP/Volumes/External" STUB_NAME="External" STUB_DEV="disk99s1"
    if ebm_detect; then fail "ebm_detect — must NOT flag a volume already at its canonical path"
    else pass "ebm_detect — clean when volume is at its canonical mount"; fi

    # ── Scenario 4: standard prefix (/opt/homebrew) → external-only gate ─────
    export EBM_BREW_PREFIX_OVERRIDE="/opt/homebrew"
    if ebm_detect; then fail "ebm_detect — must be a no-op for a standard (non-/Volumes) prefix"
    else pass "ebm_detect — no-op for standard brew prefix (external-only)"; fi

    # ── Scenario 5: phantom-safety guard ────────────────────────────────────
    export STUB_MNT="__none__"   # nothing is a mountpoint → guard decides on content
    safe="$TMP/safe"; mkdir -p "$safe/homebrew/var/log"; : > "$safe/homebrew/var/log/php-fpm.log"
    if ebm_phantom_is_safe "$safe"; then pass "ebm_phantom_is_safe — TRUE for dirs + only *.log files"
    else fail "ebm_phantom_is_safe — should accept a pure dirs+*.log phantom"; fi
    unsafe="$TMP/unsafe"; mkdir -p "$unsafe/homebrew"; echo "real user data" > "$unsafe/notes.txt"
    if ebm_phantom_is_safe "$unsafe"; then fail "ebm_phantom_is_safe — must REFUSE a dir holding a non-log file"
    else pass "ebm_phantom_is_safe — refuses to delete a dir with unexpected files"; fi
fi

echo
echo "═══ external-brew-mount — STATIC (generic-by-construction) ═══"

# macOS-gated: every entry point is a no-op off Darwin.
assert_pattern_present "$LIB" 'uname -s.*Darwin' \
    "lib — gates on uname (macOS only)"
# External-only: acts only when the prefix is under the volumes root.
assert_pattern_present "$LIB" 'case "\$prefix" in' \
    "lib — branches on the brew prefix (external-only gate)"
# Name is DERIVED from diskutil, never hardcoded.
assert_pattern_present "$LIB" 'ebm_diskutil_field "\$EBM_ACTUAL_MNT" VolumeName' \
    "lib — derives the canonical volume name from diskutil"
# No hardcoded disk NAME in executable code. The header comments legitimately
# cite the incident path, so check non-comment lines only. `/Volumes` (the bare
# mount root) is fine; `/Volumes/<name>` (a slash + a name char) is not.
hardcoded="$(grep -nE '^[[:space:]]*[^#].*/Volumes/[A-Za-z]' "$LIB" || true)"
if [[ -z "$hardcoded" ]]; then
    pass "lib — no hardcoded disk name in executable code (/Volumes/<name>)"
else
    fail "lib — hardcoded disk name in code: $hardcoded"
fi
# rm only ever runs behind the safety guard.
assert_pattern_present "$LIB" 'ebm_phantom_is_safe "\$EBM_PHANTOM"' \
    "lib — phantom removal is gated by ebm_phantom_is_safe"
assert_pattern_present "$LIB" 'find "\$dir" -mindepth 1' \
    "lib — phantom guard inspects the whole tree before deleting"
# Base-system tools only (no brew dependency in the recovery path).
assert_pattern_absent "$LIB" '(^|[^_])brew (services|install|reinstall)' \
    "lib — recovery path does not shell out to brew (works when brew is broken)"
# Re-harden reuses the canonical topic script (DRY, not a fork).
assert_pattern_present "$LIB" 'launchdaemon-hardening\.sh' \
    "lib — re-harden reuses the canonical topic hardening script"
# Regression (found in the first live e2e run): the busy-unmount branch must
# NEVER auto-run `lsof +D` piped into a consumer — it walks the whole mounted
# tree and hangs for minutes on a large volume. It may only appear as a
# suggested manual command inside a message.
assert_pattern_absent "$LIB" 'lsof \+D[^|]*\|' \
    "lib — never auto-runs 'lsof +D | …' (hang on large volumes)"

# doctor read-only wiring.
assert_pattern_present "$ROOT/scripts/runners/doctor.sh" 'check_external_brew_mount' \
    "doctor.sh — registers the external-brew-mount check"
assert_pattern_present "$ROOT/scripts/runners/doctor.sh" 'count_ext_brew_mount > 0' \
    "doctor.sh — ext-brew-mount contributes to the non-zero exit"

# The doctor command module runs the healer BEFORE setup.sh --repair and guards
# the stale path.
assert_pattern_present "$DOCTOR_MODULE" 'heal-external-brew-mount\.sh' \
    "doctor module — doctor --fix invokes the heal runner"
assert_pattern_present "$DOCTOR_MODULE" '! -d "\$repo/topics"' \
    "doctor module — detects the post-remount stale repo path and asks for a re-run"

# Runner is platform-safe + has a read-only mode.
assert_pattern_present "$RUNNER" 'ebm_supported' \
    "runner — guards on platform support (no-op off macOS)"
assert_pattern_present "$RUNNER" '[-]-report' \
    "runner — exposes a read-only --report mode"

summary
