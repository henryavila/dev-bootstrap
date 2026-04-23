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
echo "═══ pecl ini path + idempotency (no infinite reinstall loop) ═══"

# Bug class: previous code wrote conf.d ini files to
# $BREW_PREFIX/opt/php@X.Y/etc/...  (under the cellar/opt symlink).
# Brew separates etc/ from the cellar; PHP scans
# $BREW_PREFIX/etc/php/X.Y/conf.d/  and ignores anything under opt/.
# Result: extension .so installed but ini in wrong path → never loaded
# → `php -m` detection always failed → pecl reinstalled every run with
# `-f` flag forcing rebuild.

# Path correctness: ini_dir must reference $BREW_PREFIX/etc, NOT
# $prefix/etc (where prefix = $BREW_PREFIX/opt/php@X.Y).
assert_pattern_present "$LANG_MAC" 'ini_dir="\$BREW_PREFIX/etc/php' \
    "10-languages/install.mac.sh — pecl ini_dir uses \$BREW_PREFIX/etc/php (PHP-scanned)"

assert_code_absent "$LANG_MAC" 'ini_dir="\$prefix/etc/php' \
    "10-languages/install.mac.sh — pecl ini_dir does NOT use \$prefix/etc/php (orphan path)"

# pecl install must NOT have -f (force) flag — that bypasses pecl's own
# "already installed" short-circuit and forces a full rebuild even when
# nothing has changed. Combined with the wrong-path bug, this caused
# ImageMagick + igbinary + mongodb + redis to rebuild every bootstrap.
assert_code_absent "$LANG_MAC" 'pecl_bin" install -f' \
    "10-languages/install.mac.sh — pecl install does NOT use -f (no forced rebuild)"

# Multi-signal detection: php -m as primary, .so filesystem check
# (across all 3 brew paths) as fallback. We deliberately do NOT use
# `pecl list` — pecl's registry can lie (claims "installed" when .so
# is missing on disk). Filesystem is the authoritative source.
assert_pattern_present "$LANG_MAC" '_find_pecl_so "\$ext"' \
    "10-languages/install.mac.sh — detection uses multi-path .so filesystem check (not pecl registry)"

# Resolver must use php-config --extension-dir (no warning contamination)
# instead of `php -r 'echo ini_get(...);'` (which can pick up dangling-ini
# warnings on stdout when display_errors=1 in php.ini).
assert_pattern_present "$LANG_MAC" '\-\-extension-dir' \
    "10-languages/install.mac.sh — uses php-config --extension-dir (no warning contamination)"

# Ensure no ASSIGNMENT uses ini_get (comment mentioning it for documentation is fine).
assert_pattern_absent "$LANG_MAC" '[a-z_]+=.*ini_get\("extension_dir"' \
    "10-languages/install.mac.sh — no assignment via ini_get(\"extension_dir\") from php CLI (can leak warnings to stdout)"

# pecl "already installed" must be treated as success (it returns
# non-zero exit code but the .so is on disk — Path 2 in the function
# above ALSO handles this preemptively).
assert_pattern_present "$LANG_MAC" 'already installed' \
    "10-languages/install.mac.sh — pecl 'already installed' detected as success"

# Failure output must be CAPTURED + surfaced on real failures, not
# silenced. Old behavior: `>/dev/null 2>&1` masked every failure cause.
assert_code_absent "$LANG_MAC" 'pecl_bin" install [^|]*>/dev/null 2>&1' \
    "10-languages/install.mac.sh — pecl install output NOT silenced"

assert_pattern_present "$LANG_MAC" 'pecl_out=' \
    "10-languages/install.mac.sh — captures pecl output for diagnostic on failure"

# Orphan cleanup: scan and remove ini files from the old wrong path
# so re-runs do not leave dead bytes in $BREW_PREFIX/opt/php@X.Y/etc/.
assert_pattern_present "$LANG_MAC" 'orphan ini from old wrong path' \
    "10-languages/install.mac.sh — sweeps orphan inis from previous wrong-path bug"

# Truth = filesystem, not pecl registry. A previous version of this
# function trusted `pecl list` and wrote inis pointing to non-existent
# .so files (because pecl writes registry entries optimistically before
# the build completes). PHP then emitted "Unable to load dynamic library"
# warnings on every invocation. Authoritative source is the .so file
# existence at $php_bin -r 'echo ini_get("extension_dir")' / ${ext}.so.
assert_pattern_present "$LANG_MAC" 'extension_dir' \
    "10-languages/install.mac.sh — resolves extension_dir from PHP itself"

assert_pattern_present "$LANG_MAC" '_find_pecl_so\(\) \{' \
    "10-languages/install.mac.sh — defines _find_pecl_so helper for filesystem-truth detection"

# Pre-flight cleanup of stale inis (ini exists but .so missing →
# triggers PHP startup warnings on every invocation). Must run BEFORE
# detection paths so even a bailout downstream leaves PHP clean.
assert_pattern_present "$LANG_MAC" 'removing stale ini' \
    "10-languages/install.mac.sh — pre-flight removes inis pointing to missing .so"

# Recovery from pecl registry corruption: when "already installed" but
# .so missing, pecl uninstall clears the phantom registry entry, then
# install retries.
assert_pattern_present "$LANG_MAC" 'pecl_bin" uninstall' \
    "10-languages/install.mac.sh — recovers from pecl registry corruption via uninstall + retry"

echo
echo "═══ PECL 3-path reconciliation (brew in non-standard HOMEBREW_PREFIX) ═══"

# Bug class: with HOMEBREW_PREFIX=/Volumes/External/homebrew (or any prefix
# != /opt/homebrew or /usr/local), the brew-php formula does NOT create
# the lib/php/pecl/<api> → Cellar/.../pecl/<api> symlink. Three paths
# drift apart:
#   (1) ext_dir = .../Cellar/php/<ver>/lib/php/<api>/       ← where PHP loads
#   (2) pecl-cellar = .../Cellar/php/<ver>/pecl/<api>/      ← where PECL builds
#   (3) fallback = $BREW_PREFIX/lib/php/pecl/<api>/         ← never exists
# Result: `.so` is built but unreachable → every PHP invocation emits
# "Unable to load dynamic library" warnings → pre-flight nukes ini as
# "stale" → PECL rebuilds in same wrong place → infinite loop.
# Fix: _derive_pecl_cellar_dir + _find_pecl_so (search all 3 paths) +
# _reconcile_pecl_paths (symlink (1) and (3) to real file in (2)).

assert_pattern_present "$LANG_MAC" '_pecl_cellar_dir_for\(\) \{' \
    "10-languages/install.mac.sh — defines _pecl_cellar_dir_for helper (php-config backed)"

assert_pattern_present "$LANG_MAC" '_reconcile_pecl_paths\(\) \{' \
    "10-languages/install.mac.sh — defines _reconcile_pecl_paths helper"

# _find_pecl_so must search all 3 paths: (A) pecl Cellar dir, (B) brew
# fallback path (what php.ini hardcodes), (C) canonical Cellar lib/php.
assert_pattern_present "$LANG_MAC" 'pecl_cellar_dir/\$ext\.so' \
    "10-languages/install.mac.sh — _find_pecl_so checks (A) Cellar/pecl/<api> — where brew-php PECL actually writes"

assert_pattern_present "$LANG_MAC" 'BREW_PREFIX/lib/php/pecl/\$api/\$ext\.so' \
    "10-languages/install.mac.sh — _find_pecl_so checks (B) \$BREW_PREFIX/lib/php/pecl/<api> — what php.ini hardcodes"

assert_pattern_present "$LANG_MAC" 'canonical_ext_dir/\$ext\.so' \
    "10-languages/install.mac.sh — _find_pecl_so checks (C) Cellar/.../lib/php/<api> — ABI default"

# _reconcile_pecl_paths must create symlinks in fallback_dir AND canonical_ext_dir.
assert_pattern_present "$LANG_MAC" 'ln -sf "\$real_so" "\$fallback_dir' \
    "10-languages/install.mac.sh — symlinks real .so into \$BREW_PREFIX/lib/php/pecl/<api> (path B — what PHP searches)"

assert_pattern_present "$LANG_MAC" 'ln -sf "\$real_so" "\$canonical_ext_dir' \
    "10-languages/install.mac.sh — symlinks real .so into Cellar/.../lib/php/<api> (path C — ABI default)"

# Pre-flight stale-ini sweep must be gated on _find_pecl_so (all paths),
# NOT on a single path check. This was THE bug: previous code checked
# only \$ext_dir/\$ext.so, which in custom prefix never exists, so it
# nuked working inis every run → infinite reinstall loop.
assert_pattern_absent "$LANG_MAC" '\-n "\$ext_dir" && ! -f "\$so_file"' \
    "10-languages/install.mac.sh — stale-ini sweep no longer uses single-path check"

assert_pattern_present "$LANG_MAC" 'if _find_pecl_so "\$ext" "\$pecl_cellar_dir" >/dev/null' \
    "10-languages/install.mac.sh — stale-ini sweep gated on multi-path _find_pecl_so"

# Every Path 2/3 success branch must call _reconcile_pecl_paths before
# _ensure_ini, so the symlinks exist before PHP tries to load.
reconcile_count=$(_count_matches '_reconcile_pecl_paths "\$ext" "\$pecl_cellar_dir"' "$LANG_MAC")
if [[ "$reconcile_count" -ge 3 ]]; then
    pass "10-languages/install.mac.sh — _reconcile_pecl_paths called on all success paths (count=$reconcile_count, expected ≥3)"
else
    fail "10-languages/install.mac.sh — _reconcile_pecl_paths called only $reconcile_count times (expected ≥3: pre-flight, Path 2, Path 3 + Path 3 retry)"
fi

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

# Case-insensitive marker check: templates write "Managed by dev-bootstrap"
# (capital M), health-checks must use grep -i. A case-sensitive check caused
# the nginx migration block to re-migrate already-migrated files on EVERY run,
# producing one .pre-bootstrap-bak-<ts> backup per execution. Regression found
# 2026-04-23 with 6 backups stacked up in 24h on M2.
assert_pattern_present "$MAC" 'grep -qi "managed by dev-bootstrap"' \
    "60-web-stack/install.mac.sh — migration marker check is case-insensitive (grep -qi)"

assert_pattern_absent "$MAC" 'grep -q "managed by dev-bootstrap"' \
    "60-web-stack/install.mac.sh — no case-sensitive marker check (would loop-migrate)"

assert_pattern_present "$ROOT/lib/deploy.sh" 'grep -qiF "managed by dev-bootstrap"' \
    "lib/deploy.sh — overwrite-protection marker check is case-insensitive"

assert_pattern_absent "$ROOT/lib/deploy.sh" 'grep -qF "managed by dev-bootstrap"' \
    "lib/deploy.sh — no case-sensitive marker check in overwrite protection"

assert_pattern_present "$WSL" 'grep -qi "managed by dev-bootstrap"' \
    "60-web-stack/install.wsl.sh — legacy catchall removal marker check is case-insensitive"

echo
echo "═══ fzf shell integration: do NOT source completion.zsh (fzf-tab owns TAB) ═══"

# Regression 2026-04-23: fzf's completion.zsh runs \`bindkey '^I' fzf-completion\`
# at the end of its source, which races against fzf-tab's own TAB rebinding.
# When fzf-tab fails to load (turbo regression, zinit issue, etc.), TAB stays
# stuck on the primitive fzf-completion — user reports "autocomplete not
# contextual". Defense in depth: only source key-bindings.zsh (Ctrl-R / Ctrl-T
# / Alt-C); TAB is owned exclusively by fzf-tab, falling back to native zsh
# \`expand-or-complete\` if fzf-tab is unavailable.
TUX_ZSH="$ROOT/topics/20-terminal-ux/templates/zshrc.d-20-terminal-ux.sh.template"

assert_pattern_absent "$TUX_ZSH" 'shell/completion\.zsh' \
    "20-terminal-ux zsh template — does NOT source fzf's completion.zsh (stomps TAB / fzf-tab)"

assert_pattern_present "$TUX_ZSH" 'shell/key-bindings\.zsh' \
    "20-terminal-ux zsh template — DOES source fzf key-bindings.zsh (Ctrl-R / Ctrl-T / Alt-C)"

echo
echo "═══ Per-version composer wrappers (composer8.4, composer8.3, …) ═══"

# Feature: `composer` (no suffix) always binds to \$PHP_DEFAULT. For every
# OTHER version in \$PHP_VERSIONS, generate ~/.local/bin/composer<maj.min>
# that runs Composer via that specific PHP binary. Lets users do
# `composer8.4 install` in a shell where the default PHP is 8.5, without
# flipping the global alternative via php-use.

# Mac: wrapper uses \$BREW_PREFIX/opt/php@<ver>/bin/php + \$BREW_PREFIX/bin/composer
assert_pattern_present "$LANG_MAC" 'composer\$\{ver\}' \
    "10-languages/install.mac.sh — declares composer\${ver} wrapper path"

assert_pattern_present "$LANG_MAC" '\[\[ "\$ver" == "\$PHP_DEFAULT" \]\] && continue' \
    "10-languages/install.mac.sh — skips wrapper for PHP_DEFAULT (redundant with plain composer)"

assert_pattern_present "$LANG_MAC" 'BREW_PREFIX/opt/php@\$\{ver\}/bin/php' \
    "10-languages/install.mac.sh — wrapper points to correct php binary path for Mac"

assert_pattern_present "$LANG_MAC" 'chmod \+x "\$_wrapper"' \
    "10-languages/install.mac.sh — wrapper is made executable"

# WSL: wrapper uses /usr/bin/php<ver> + /usr/local/bin/composer
LANG_WSL="$ROOT/topics/10-languages/install.wsl.sh"

assert_pattern_present "$LANG_WSL" 'composer\$\{ver\}' \
    "10-languages/install.wsl.sh — declares composer\${ver} wrapper path"

assert_pattern_present "$LANG_WSL" '\[\[ "\$ver" == "\$PHP_DEFAULT" \]\] && continue' \
    "10-languages/install.wsl.sh — skips wrapper for PHP_DEFAULT"

assert_pattern_present "$LANG_WSL" '/usr/bin/php\$\{ver\}' \
    "10-languages/install.wsl.sh — wrapper points to /usr/bin/php<ver> (WSL layout)"

assert_pattern_present "$LANG_WSL" 'chmod \+x "\$_wrapper"' \
    "10-languages/install.wsl.sh — wrapper is made executable"

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
