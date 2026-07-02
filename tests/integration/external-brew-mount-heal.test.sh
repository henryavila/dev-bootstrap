#!/usr/bin/env bash
# tests/integration/external-brew-mount-heal.test.sh
#
# Covers scripts/lib/external-brew-mount.sh + the heal runner + the doctor /
# bin/mesh wiring for the macOS external-brew mount-disambiguation failure
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
#    (so plain dirs read as "not a mounted volume", i.e. phantoms). It also
#    records mount/unmount calls for ebm_heal remount tests. ──────────────────
make_diskutil_stub() {
    local path="$1"
    cat > "$path" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_LOG:-/dev/null}"
if [[ "$1" == "info" && "$2" == "-plist" ]]; then
    mnt="$3"
    expected="${STUB_MNT:-}"
    if [[ -n "${STUB_MOUNTED_CANONICAL_STATE:-}" && -f "$STUB_MOUNTED_CANONICAL_STATE" ]]; then
        expected="${STUB_CANONICAL_MNT:-$expected}"
    fi
    [[ "$mnt" == "$expected" ]] || exit 1
    cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>VolumeName</key><string>${STUB_NAME:-}</string>
<key>DeviceIdentifier</key><string>${STUB_DEV:-}</string>
<key>MountPoint</key><string>${mnt}</string>
</dict></plist>
XML
    exit 0
fi
if [[ "$1" == "unmount" && "$2" == "force" ]]; then
    exit "${STUB_FORCE_UNMOUNT_RC:-0}"
fi
if [[ "$1" == "unmount" ]]; then
    exit "${STUB_UNMOUNT_RC:-0}"
fi
if [[ "$1" == "mount" ]]; then
    [[ "$2" == "${STUB_DEV:-}" ]] || exit 1
    [[ -n "${STUB_MOUNTED_CANONICAL_STATE:-}" ]] && : > "$STUB_MOUNTED_CANONICAL_STATE"
    exit "${STUB_MOUNT_RC:-0}"
fi
exit 1
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

    # ── Scenario 6: reported bug — when mesh doctor --fix is launched from
    #    inside the affected volume, the normal unmount can fail as busy. The
    #    healer must force the unmount and remount automatically.
    ebm_reharden() { return 0; }
    ebm_priv() {
        [[ "${1:-}" == "launchctl" ]] && return 0
        "$@"
    }
    rm -f "$TMP/diskutil.log" "$TMP/mounted-canonical" "$TMP/heal.err"
    rm -rf "$TMP/Volumes/External" "$TMP/Volumes/External 1"
    mkdir -p "$TMP/Volumes/External 1/homebrew"
    mkdir -p "$TMP/Volumes/External/homebrew/var/log"
    : > "$TMP/Volumes/External/homebrew/var/log/php-fpm.log"
    export EBM_BREW_PREFIX_OVERRIDE="$TMP/Volumes/External 1/homebrew"
    export STUB_MNT="$TMP/Volumes/External 1" STUB_NAME="External" STUB_DEV="disk99s1"
    export STUB_CANONICAL_MNT="$TMP/Volumes/External" STUB_LOG="$TMP/diskutil.log"
    export STUB_MOUNTED_CANONICAL_STATE="$TMP/mounted-canonical"
    export STUB_UNMOUNT_RC=16 STUB_FORCE_UNMOUNT_RC=0 STUB_MOUNT_RC=0
    if ebm_heal >/dev/null 2>"$TMP/heal.err"; then pass "ebm_heal — busy unmount collision exits successfully"
    else fail "ebm_heal — busy unmount collision should be healed automatically"; fi
    assert_eq "$EBM_REMOUNTED" "1" "ebm_heal — busy unmount path remounts at the canonical path"
    assert_pattern_present "$TMP/diskutil.log" '^unmount force '"$TMP"'/Volumes/External 1$' \
        "ebm_heal — retries a busy unmount with diskutil unmount force"
    assert_pattern_present "$TMP/diskutil.log" '^mount disk99s1$' \
        "ebm_heal — mounts the device after the forced unmount"

    # ── Scenario 7: normal unmount works → no forced unmount needed.
    rm -f "$TMP/diskutil.log" "$TMP/mounted-canonical" "$TMP/heal.err"
    rm -rf "$TMP/Volumes/External" "$TMP/Volumes/External 1"
    mkdir -p "$TMP/Volumes/External 1/homebrew"
    mkdir -p "$TMP/Volumes/External/homebrew/var/log"
    : > "$TMP/Volumes/External/homebrew/var/log/php-fpm.log"
    export STUB_MNT="$TMP/Volumes/External 1" STUB_NAME="External" STUB_DEV="disk99s1"
    export STUB_UNMOUNT_RC=0 STUB_FORCE_UNMOUNT_RC=0 STUB_MOUNT_RC=0
    if ebm_heal >/dev/null 2>"$TMP/heal.err"; then pass "ebm_heal — normal unmount collision exits successfully"
    else fail "ebm_heal — normal unmount collision should be healed"; fi
    assert_eq "$EBM_REMOUNTED" "1" "ebm_heal — normal unmount path remounts at the canonical path"
    assert_pattern_absent "$TMP/diskutil.log" '^unmount force ' \
        "ebm_heal — does not force unmount when normal unmount succeeds"

    # ── Scenario 8: normal and forced unmount both fail → unresolved is non-zero.
    rm -f "$TMP/diskutil.log" "$TMP/mounted-canonical" "$TMP/heal.err"
    rm -rf "$TMP/Volumes/External" "$TMP/Volumes/External 1"
    mkdir -p "$TMP/Volumes/External 1/homebrew"
    mkdir -p "$TMP/Volumes/External/homebrew/var/log"
    : > "$TMP/Volumes/External/homebrew/var/log/php-fpm.log"
    export STUB_MNT="$TMP/Volumes/External 1" STUB_NAME="External" STUB_DEV="disk99s1"
    export STUB_UNMOUNT_RC=16 STUB_FORCE_UNMOUNT_RC=16 STUB_MOUNT_RC=0
    if ebm_heal >/dev/null 2>"$TMP/heal.err"; then fail "ebm_heal — failed forced unmount must not look repaired"
    else pass "ebm_heal — failed forced unmount returns non-zero"; fi
    assert_eq "$EBM_REMOUNTED" "0" "ebm_heal — failed forced unmount leaves remounted flag unset"
    assert_pattern_absent "$TMP/diskutil.log" '^mount disk99s1$' \
        "ebm_heal — does not mount when forced unmount fails"

    echo
    echo "═══ external-brew-mount — BIN/MESH (stubbed stale-path re-entry) ═══"
    old_repo="$TMP/Bin Volumes/External 1/code/mesh-workstation"
    new_repo="$TMP/Bin Volumes/External/code/mesh-workstation"
    mkdir -p "$old_repo/scripts/lib" "$old_repo/scripts/runners" "$old_repo/topics"
    cat > "$old_repo/scripts/lib/external-brew-mount.sh" <<STUB
ebm_detect() {
    EBM_ACTUAL_MNT="$TMP/Bin Volumes/External 1"
    EBM_CANONICAL_MNT="$TMP/Bin Volumes/External"
    return 0
}
STUB
    cat > "$old_repo/scripts/runners/heal-external-brew-mount.sh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
mkdir -p "$(dirname "$new_repo")"
mv "$old_repo" "$new_repo"
STUB
    cat > "$old_repo/scripts/runners/doctor.sh" <<'STUB'
#!/usr/bin/env bash
printf 'doctor %s\n' "$*" >> "$MESH_TEST_LOG"
printf 'doctor-pwd %s\n' "$(pwd -P)" >> "$MESH_TEST_LOG"
STUB
    cat > "$old_repo/setup.sh" <<'STUB'
#!/usr/bin/env bash
printf 'setup %s\n' "$*" >> "$MESH_TEST_LOG"
printf 'setup-pwd %s\n' "$(pwd -P)" >> "$MESH_TEST_LOG"
STUB
    chmod +x "$old_repo/scripts/runners/heal-external-brew-mount.sh" "$old_repo/scripts/runners/doctor.sh" "$old_repo/setup.sh"
    MESH_WORKSTATION_DIR="$old_repo" MESH_HOME="$old_repo/scripts" MESH_TEST_LOG="$TMP/binmesh.log" \
        bash "$ROOT/bin/mesh" doctor --fix >"$TMP/binmesh.out" 2>"$TMP/binmesh.err"
    assert_eq "$?" "0" "bin/mesh — stale-path remount flow exits successfully"
    assert_file_contains "$TMP/binmesh.log" '^doctor --fix --quiet$' \
        "bin/mesh — continues drift repair from the canonical repo after remount"
    assert_file_contains "$TMP/binmesh.log" '^setup --repair$' \
        "bin/mesh — continues setup repair from the canonical repo after remount"
    doctor_pwd="$(awk '/^doctor-pwd /{sub(/^doctor-pwd /,""); print; exit}' "$TMP/binmesh.log")"
    setup_pwd="$(awk '/^setup-pwd /{sub(/^setup-pwd /,""); print; exit}' "$TMP/binmesh.log")"
    new_repo_physical="$(cd "$new_repo" && pwd -P)"
    assert_eq "$doctor_pwd" "$new_repo_physical" \
        "bin/mesh — drift repair runs with cwd moved to the canonical repo"
    assert_eq "$setup_pwd" "$new_repo_physical" \
        "bin/mesh — setup repair runs with cwd moved to the canonical repo"
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

# bin/mesh runs the healer BEFORE setup.sh --repair and guards the stale path.
assert_pattern_present "$ROOT/bin/mesh" 'heal-external-brew-mount\.sh' \
    "bin/mesh — doctor --fix invokes the heal runner"
assert_pattern_absent "$ROOT/bin/mesh" 'bash "\$healer" \|\| true' \
    "bin/mesh — doctor --fix does not mask heal runner failure"
assert_pattern_present "$ROOT/bin/mesh" '! -d "\$repo/topics"' \
    "bin/mesh — detects the post-remount stale repo path and asks for a re-run"

# Runner is platform-safe + has a read-only mode.
assert_pattern_present "$RUNNER" 'ebm_supported' \
    "runner — guards on platform support (no-op off macOS)"
assert_pattern_present "$RUNNER" '[-]-report' \
    "runner — exposes a read-only --report mode"

summary
