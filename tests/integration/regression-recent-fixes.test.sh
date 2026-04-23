#!/usr/bin/env bash
# tests/integration/regression-recent-fixes.test.sh
#
# Static regression tests for the bug class fixed in the 2026-04-22 session.
# Each fix corresponds to either a presence assertion (the fix is in place)
# or an absence assertion (the anti-pattern is gone). Grep-based — no mocking,
# no actual command execution — fast, deterministic, impossible to bypass
# silently.
#
# When adding a new fix in the same class, append the corresponding test
# below so future refactors cannot quietly regress the behavior.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

WSL="$ROOT/topics/60-web-stack/install.wsl.sh"
MAC="$ROOT/topics/60-web-stack/install.mac.sh"
LANG_MAC="$ROOT/topics/10-languages/install.mac.sh"
REMOTE_MAC="$ROOT/topics/70-remote-access/install.mac.sh"
BOOTSTRAP="$ROOT/bootstrap.sh"
MENU="$ROOT/lib/menu.sh"

# Helper: count matches of an extended regex in a file (works on bash 3.2)
_count_matches() {
    local pattern="$1" file="$2"
    grep -cE "$pattern" "$file" 2>/dev/null || echo 0
}

# Helper: assert pattern appears at least once in file
assert_pattern_present() {
    local file="$1" pattern="$2" msg="$3"
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' not found in $file)"
    fi
}

# Helper: assert pattern does NOT appear in file
assert_pattern_absent() {
    local file="$1" pattern="$2" msg="$3"
    if ! grep -qE "$pattern" "$file" 2>/dev/null; then
        pass "$msg"
    else
        local matches
        matches=$(grep -nE "$pattern" "$file" 2>/dev/null | head -3)
        fail "$msg (anti-pattern '$pattern' found in $file)"
        printf "      first matches:\n%s\n" "$matches" | sed 's/^/        /' >&2
    fi
}

# Helper: assert pattern absent in CODE (excludes comment-only lines).
# A "comment-only line" is one whose first non-whitespace character is #.
# Inline comments (`code # comment`) still count as code — that's correct
# because the code itself is what we test for.
assert_code_absent() {
    local file="$1" pattern="$2" msg="$3"
    local matches
    matches=$(grep -nE "$pattern" "$file" 2>/dev/null \
        | grep -vE '^[[:digit:]]+:[[:space:]]*#' || true)
    if [[ -z "$matches" ]]; then
        pass "$msg"
    else
        fail "$msg (anti-pattern '$pattern' found as CODE in $file)"
        printf "      first matches:\n%s\n" "$(echo "$matches" | head -3)" \
            | sed 's/^/        /' >&2
    fi
}

echo
echo "═══ apt-get must show progress + auto-accept defaults (no -qq, no debconf prompts) ═══"

assert_pattern_absent "$WSL" 'apt-get [^|]*-qq' \
    "60-web-stack/install.wsl.sh — no apt-get -qq (silences progress + sudo prompts)"

assert_pattern_present "$WSL" 'DEBIAN_FRONTEND=noninteractive' \
    "60-web-stack/install.wsl.sh — exports DEBIAN_FRONTEND=noninteractive"

assert_pattern_present "$WSL" 'force-confdef' \
    "60-web-stack/install.wsl.sh — passes Dpkg --force-confdef (no interactive merge)"

echo
echo "═══ Sudo cache refresh at topic entry (long topics outlast 5-15min cache) ═══"

assert_pattern_present "$WSL" 'sudo -v' \
    "60-web-stack/install.wsl.sh — sudo -v keepalive at topic entry"

# 60-web-stack/install.mac.sh has its own sudo -v before the valet block
assert_pattern_present "$MAC" 'sudo -v' \
    "60-web-stack/install.mac.sh — sudo -v before valet command block"

echo
echo "═══ mkcert -install: visible stderr on Linux, absent entirely on Mac ═══"

# Linux still calls mkcert -install (we own the trust store there) but
# without 2>/dev/null silencing — sudo prompt must surface.
assert_pattern_present "$WSL" 'mkcert -install' \
    "60-web-stack/install.wsl.sh — Linux still calls mkcert -install (own trust store)"

assert_pattern_absent "$WSL" 'mkcert -install 2>/dev/null' \
    "60-web-stack/install.wsl.sh — mkcert -install stderr NOT silenced"

# Mac MUST NOT call mkcert -install — Valet handles via valet install + valet secure.
# We use assert_code_absent to allow the explanatory comments documenting the
# intentional asymmetry (Linux owns trust store, Mac delegates to Valet).
assert_code_absent "$MAC" 'mkcert -install' \
    "60-web-stack/install.mac.sh — mkcert -install absent (Valet handles)"

echo
echo "═══ PowerShell interop wrapped in timeout (binfmt_misc/9P stall protection) ═══"

assert_pattern_present "$WSL" 'timeout.*45' \
    "60-web-stack/install.wsl.sh — PowerShell interop wrapped in 'timeout 45'"

echo
echo "═══ valet install: skip-when-healthy + FORCE_VALET_INSTALL=1 escape hatch ═══"

assert_pattern_present "$MAC" 'FORCE_VALET_INSTALL' \
    "60-web-stack/install.mac.sh — FORCE_VALET_INSTALL env var supported"

assert_pattern_present "$MAC" 'skipping valet install' \
    "60-web-stack/install.mac.sh — skip-when-healthy branch present"

# valet install / valet tld / valet park stderr must NOT be suppressed
# (sudo prompts inside those commands need to surface)
assert_pattern_absent "$MAC" 'valet install --quiet >/dev/null 2>&1' \
    "60-web-stack/install.mac.sh — valet install stderr NOT silenced"

assert_pattern_absent "$MAC" 'tld localhost >/dev/null 2>&1' \
    "60-web-stack/install.mac.sh — valet tld stderr NOT silenced"

# Valet 4.x added a "Using a custom TLD is no longer officially supported"
# confirmation prompt with default N. Without piping y, bootstrap hangs
# waiting on stdin. printf 'y\n' auto-confirms.
assert_pattern_present "$MAC" "printf 'y" \
    "60-web-stack/install.mac.sh — valet tld auto-confirms the 'unsupported TLD' prompt"

assert_pattern_absent "$MAC" 'park --quiet >/dev/null 2>&1' \
    "60-web-stack/install.mac.sh — valet park stderr NOT silenced"

echo
echo "═══ /etc/paths.d/ injection for non-standard BREW_PREFIX (Mac sshd-exec PATH) ═══"

assert_pattern_present "$REMOTE_MAC" '/etc/paths.d/60-extbrew' \
    "70-remote-access/install.mac.sh — writes /etc/paths.d/60-extbrew for non-standard prefix"

assert_pattern_present "$REMOTE_MAC" 'symlinked mosh-server' \
    "70-remote-access/install.mac.sh — belt-and-suspenders symlink in /usr/local/bin"

assert_pattern_present "$MAC" '/etc/paths.d/61-oracle-mysql' \
    "60-web-stack/install.mac.sh — writes /etc/paths.d/61-oracle-mysql for Oracle DMG"

echo
echo "═══ brew_install_if_missing 3-tier retry (Tier 3 --HEAD bypasses checksum) ═══"

assert_pattern_present "$LANG_MAC" 'BREW_INSTALL_FAILED' \
    "10-languages/install.mac.sh — tracks failed installs in BREW_INSTALL_FAILED array"

assert_pattern_present "$LANG_MAC" 'Tier 1' \
    "10-languages/install.mac.sh — Tier 1 retry (refresh + clear cache)"

assert_pattern_present "$LANG_MAC" 'Tier 2.*build-from-source' \
    "10-languages/install.mac.sh — Tier 2 retry (--build-from-source)"

assert_pattern_present "$LANG_MAC" 'Tier 3.*HEAD' \
    "10-languages/install.mac.sh — Tier 3 retry (--HEAD bypasses tarball checksum)"

assert_pattern_present "$LANG_MAC" 'has_head' \
    "10-languages/install.mac.sh — probes formula for HEAD spec before invoking --HEAD"

echo
echo "═══ Pre-migration of legacy unmarked nginx files (60-web-stack mac) ═══"

assert_pattern_present "$MAC" 'pre-bootstrap-bak' \
    "60-web-stack/install.mac.sh — backs up legacy unmarked files before deploy"

assert_pattern_present "$MAC" 'managed by dev-bootstrap' \
    "60-web-stack/install.mac.sh — checks for marker before touching legacy files"

# Allowlist: only specific paths are migrated (not arbitrary deletions)
assert_pattern_present "$MAC" 'LEGACY_FILES=' \
    "60-web-stack/install.mac.sh — explicit allowlist of paths to migrate"

echo
echo "═══ Topic rename complete: no '60-laravel-stack' references in code ═══"

# Allow:
#   - this test file itself (self-references the string in regex literals)
#   - comment lines explaining the rename history (`# was 60-laravel-stack ...`)
# Forbid: any actual code reference to the old topic name.
laravel_refs=$(grep -rn '60-laravel-stack' "$ROOT" \
    --include='*.sh' --include='*.md' --include='*.ps1' \
    --include='*.txt' --include='*.conf' --include='*.template' \
    2>/dev/null \
    | grep -v "$HERE/regression-recent-fixes.test.sh" \
    | grep -vE ':[[:space:]]*#' \
    | grep -vE '^\.git/' \
    || true)
ref_count=$(printf '%s\n' "$laravel_refs" | grep -c . || true)
if [[ "${ref_count:-0}" -eq 0 ]]; then
    pass "no '60-laravel-stack' code references remain (rename complete)"
else
    fail "'60-laravel-stack' still referenced in code:"
    printf '%s\n' "$laravel_refs" | sed 's/^/        /' >&2
fi

echo
echo "═══ INCLUDE_LARAVEL → INCLUDE_WEBSTACK back-compat alias ═══"

assert_pattern_present "$BOOTSTRAP" 'INCLUDE_LARAVEL.*INCLUDE_WEBSTACK' \
    "bootstrap.sh — legacy INCLUDE_LARAVEL aliases to INCLUDE_WEBSTACK"

# The alias check must happen BEFORE export INCLUDE_WEBSTACK, otherwise
# the alias would set after the canonical default already initialized to 0.
alias_line=$(grep -n 'INCLUDE_WEBSTACK="\$INCLUDE_LARAVEL"' "$BOOTSTRAP" | head -1 | cut -d: -f1)
export_line=$(grep -n 'export INCLUDE_WEBSTACK="${INCLUDE_WEBSTACK:-0}"' "$BOOTSTRAP" | head -1 | cut -d: -f1)
if [[ -n "$alias_line" && -n "$export_line" ]] && [[ "$alias_line" -lt "$export_line" ]]; then
    pass "INCLUDE_LARAVEL alias resolved BEFORE INCLUDE_WEBSTACK default-export"
else
    fail "INCLUDE_LARAVEL alias must come before INCLUDE_WEBSTACK default (alias=$alias_line, export=$export_line)"
fi

# Menu uses webstack keyword (not legacy 'laravel')
assert_pattern_present "$MENU" '"webstack"' \
    "lib/menu.sh — menu keyword renamed to 'webstack'"

assert_pattern_absent "$MENU" 'export INCLUDE_LARAVEL=1' \
    "lib/menu.sh — does NOT export legacy INCLUDE_LARAVEL (write canonical name only)"

echo
echo "═══ State file persists canonical INCLUDE_WEBSTACK only ═══"

assert_pattern_present "$MENU" "echo 'export INCLUDE_WEBSTACK=1'" \
    "lib/menu.sh — state file persists canonical INCLUDE_WEBSTACK"

assert_pattern_absent "$MENU" "echo 'export INCLUDE_LARAVEL=1'" \
    "lib/menu.sh — state file does NOT persist legacy INCLUDE_LARAVEL"

echo
summary
