#!/usr/bin/env bash
# tests/integration/launchdaemon-volume-paths.test.sh
#
# Regression: bug discovered 2026-05-02 on M2 (Mac, brew on external 2TB SSD).
#
# After Apr 22 21:39 (`valet install` first ran), 3 LaunchDaemons were
# created in /Library/LaunchDaemons/ with absolute paths burned in pointing
# to /Volumes/External/homebrew/. Mac wasn't rebooted for 9 days. On the
# first reboot (May 2 06:04), launchd loaded `homebrew.mxcl.php.plist`
# before the external USB-C disk finished mounting; opening its
# `StandardErrorPath` (= /Volumes/External/homebrew/var/log/php-fpm.log)
# with O_CREAT triggered `mkdir -p` of the parent on rootfs, creating a
# phantom `/Volumes/External/homebrew/var/log/` (root:wheel, 0755).
# When the real disk mounted, diskarbitrationd disambiguated the
# collision by suffixing the mount path → `/Volumes/External 1`, breaking:
#   - cached PATH in shell sessions
#   - 16+ repos at /Volumes/External/code/
#   - all subsequent system + user-scope brew services (exit 78)
#   - dev-bootstrap recovery (detect-brew hardcoded /Volumes/External/...)
#
# Two-pronged defense, both grep-asserted here:
#   (1) topics/60-web-stack/install.mac.sh — POST-`valet install`,
#       rewrite Standard{Error,Out}Path of the 3 brew daemon plists to
#       /var/log/homebrew/<svc>.log (rootfs path, always writable, no
#       phantom possible). ProgramArguments stays on external; daemon
#       fails until disk mounts (KeepAlive retries) but `posix_spawn`
#       doesn't mkdir → no phantom.
#   (2) lib/detect-brew.sh — glob /Volumes/External*/homebrew/bin/brew
#       so recovery scripts find brew even if the disambiguation already
#       happened (path with space).
#
# Full forensic in feedback_launchdaemon_phantom_volumes_mkdir_race.md.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

WEB_MAC="$ROOT/topics/60-web-stack/install.mac.sh"
DETECT="$ROOT/lib/detect-brew.sh"

assert_pattern_present() {
    local file="$1" pattern="$2" msg="$3"
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' not found in $file)"
    fi
}

assert_pattern_absent() {
    local file="$1" pattern="$2" msg="$3"
    if ! grep -qE "$pattern" "$file" 2>/dev/null; then
        pass "$msg"
    else
        fail "$msg (anti-pattern '$pattern' found in $file)"
    fi
}

echo
echo "═══ 60-web-stack/install.mac.sh — LaunchDaemon hardening ═══"

# Block must exist: case "$BREW_PREFIX" with non-standard branch
assert_pattern_present "$WEB_MAC" 'case "\$BREW_PREFIX" in' \
    "60-web-stack/install.mac.sh — gates hardening on BREW_PREFIX (case statement)"

# Standard prefixes (/opt/homebrew, /usr/local) explicitly skip
assert_pattern_present "$WEB_MAC" '/opt/homebrew\|/usr/local' \
    "60-web-stack/install.mac.sh — names /opt/homebrew and /usr/local as standard (skip path)"

# Uses PlistBuddy (Apple's canonical plist editor; idempotent Set)
assert_pattern_present "$WEB_MAC" '/usr/libexec/PlistBuddy' \
    "60-web-stack/install.mac.sh — uses /usr/libexec/PlistBuddy for surgical plist edits"

# Targets BOTH StandardErrorPath and StandardOutPath
assert_pattern_present "$WEB_MAC" 'StandardErrorPath' \
    "60-web-stack/install.mac.sh — rewrites StandardErrorPath"
assert_pattern_present "$WEB_MAC" 'StandardOutPath' \
    "60-web-stack/install.mac.sh — rewrites StandardOutPath"

# Target log dir is /var/log/homebrew/* (rootfs path, not /Volumes/*)
assert_pattern_present "$WEB_MAC" '/var/log/homebrew' \
    "60-web-stack/install.mac.sh — Standard*Path moves to /var/log/homebrew/ (rootfs)"

# Creates the target log dir (so PlistBuddy + launchd can write there)
assert_pattern_present "$WEB_MAC" 'mkdir -p /var/log/homebrew' \
    "60-web-stack/install.mac.sh — creates /var/log/homebrew/ before pointing plists at it"

# Re-applies the change to launchd via bootout + bootstrap
assert_pattern_present "$WEB_MAC" 'launchctl bootout .system/homebrew\.mxcl' \
    "60-web-stack/install.mac.sh — bootouts each modified daemon to flush in-memory state"
assert_pattern_present "$WEB_MAC" 'launchctl bootstrap system' \
    "60-web-stack/install.mac.sh — re-bootstraps each modified daemon"

# Covers all 3 services that valet install spawns (loop-based, robust to refactor)
assert_pattern_present "$WEB_MAC" 'for svc in php nginx dnsmasq' \
    "60-web-stack/install.mac.sh — iterates over php / nginx / dnsmasq services"

# Idempotence guard: change-tracking flag + read-before-write check
assert_pattern_present "$WEB_MAC" '_hardening_changed=' \
    "60-web-stack/install.mac.sh — tracks whether any plist was actually changed (idempotence)"

# Negative: no NEW absolute reference to /Volumes/External/homebrew/var/
# (only the comment that explains the bug may mention the phantom path)
non_comment_volumes_paths="$(grep -nE '^[^#]*StandardErrorPath.*"/Volumes/' "$WEB_MAC" || true)"
if [[ -z "$non_comment_volumes_paths" ]]; then
    pass "60-web-stack/install.mac.sh — no executable code writes Standard*Path to /Volumes/*"
else
    fail "60-web-stack/install.mac.sh — found Standard*Path → /Volumes/* in non-comment line: $non_comment_volumes_paths"
fi

echo
echo "═══ lib/detect-brew.sh — glob fallback for mount-point disambiguation ═══"

# Glob handles the /Volumes/External* family (External, External 1, etc.)
assert_pattern_present "$DETECT" '/Volumes/External\*/homebrew/bin/brew' \
    "lib/detect-brew.sh — glob /Volumes/External*/homebrew/bin/brew (handles disambiguation suffix)"

# Uses nullglob so empty match doesn't insert literal pattern as candidate
assert_pattern_present "$DETECT" 'shopt -s nullglob' \
    "lib/detect-brew.sh — sets nullglob before glob iteration"

# Bash 3.2 safe: does NOT use `shopt -p` capture pattern (exits 1 for unset
# options on bash 3.2 + `set -e` aborts silently). See
# feedback_bash32_compat_macos.md.
assert_pattern_absent "$DETECT" 'shopt -p nullglob' \
    "lib/detect-brew.sh — avoids 'shopt -p' capture (bash 3.2 + set -e abort hazard)"

# Restores nullglob to its prior state (off by default)
assert_pattern_present "$DETECT" 'shopt -u nullglob' \
    "lib/detect-brew.sh — restores nullglob to off when it was off before"

# Does NOT hardcode literal /Volumes/External/homebrew/bin/brew anymore
# (the glob covers it; keeping the literal would shadow the disambiguation
# case where /Volumes/External is a phantom dir without bin/brew)
assert_pattern_absent "$DETECT" '"/Volumes/External/homebrew/bin/brew"' \
    "lib/detect-brew.sh — removed literal /Volumes/External/... candidate (glob supersedes)"

summary
