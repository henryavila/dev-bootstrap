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

# Wrapper resolves composer at RUN time via EXPLICIT priority list:
# ~/.local/bin/composer > /usr/local/bin/composer > $BREW_PREFIX/bin/composer.
# Avoids `command -v composer` as primary lookup because PATH order on
# Mac puts $BREW_PREFIX/bin ahead of ~/.local/bin — resolving brew's
# composer which has a broken PHAR signature on this machine class.
assert_pattern_present "$LANG_MAC" '\$HOME/\.local/bin/composer' \
    "10-languages/install.mac.sh — wrapper prefers ~/.local/bin/composer (highest priority)"

assert_pattern_present "$LANG_MAC" '/usr/local/bin/composer' \
    "10-languages/install.mac.sh — wrapper falls back to /usr/local/bin/composer"

assert_pattern_present "$LANG_MAC" 'command -v composer' \
    "10-languages/install.mac.sh — wrapper has PATH-lookup last-resort fallback"

assert_pattern_absent "$LANG_MAC" 'exec "\$\{_php_bin\}" "\$\{_composer_bin\}"' \
    "10-languages/install.mac.sh — does NOT bake \$BREW_PREFIX/bin/composer into wrapper"

# WSL: wrapper uses /usr/bin/php<ver> + runtime-resolved composer
LANG_WSL="$ROOT/topics/10-languages/install.wsl.sh"

assert_pattern_present "$LANG_WSL" 'composer\$\{ver\}' \
    "10-languages/install.wsl.sh — declares composer\${ver} wrapper path"

assert_pattern_present "$LANG_WSL" '\[\[ "\$ver" == "\$PHP_DEFAULT" \]\] && continue' \
    "10-languages/install.wsl.sh — skips wrapper for PHP_DEFAULT"

assert_pattern_present "$LANG_WSL" '/usr/bin/php\$\{ver\}' \
    "10-languages/install.wsl.sh — wrapper points to /usr/bin/php<ver> (WSL layout)"

assert_pattern_present "$LANG_WSL" 'chmod \+x "\$_wrapper"' \
    "10-languages/install.wsl.sh — wrapper is made executable"

assert_pattern_present "$LANG_WSL" '\$HOME/\.local/bin/composer' \
    "10-languages/install.wsl.sh — wrapper prefers ~/.local/bin/composer (highest priority)"

assert_pattern_present "$LANG_WSL" 'command -v composer' \
    "10-languages/install.wsl.sh — wrapper has PATH-lookup last-resort fallback"

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
echo "═══ 2026-04-23 : auto-chsh + secrets.env scaffold ═══"

# Issue 1 — zsh auto-chsh. Bootstrap must try sudo chsh/usermod before
# falling through to the advisory, default-on, CHSH_AUTO=0 opts out.
TUX_WSL="$ROOT/topics/20-terminal-ux/install.wsl.sh"
TUX_MAC="$ROOT/topics/20-terminal-ux/install.mac.sh"

assert_pattern_present "$TUX_WSL" 'CHSH_AUTO:-1' \
    "20-terminal-ux/install.wsl.sh — CHSH_AUTO defaults to 1 (auto-on)"

assert_pattern_present "$TUX_WSL" 'sudo -n chsh -s' \
    "20-terminal-ux/install.wsl.sh — attempts sudo chsh with cached ticket"

assert_pattern_present "$TUX_WSL" 'sudo -n usermod -s' \
    "20-terminal-ux/install.wsl.sh — falls back to sudo usermod when chsh refused"

assert_pattern_present "$TUX_WSL" 'grep -qxF "\$zsh_bin" /etc/shells' \
    "20-terminal-ux/install.wsl.sh — /etc/shells check before chsh"

# LDAP/SSSD fallback: chsh returns 0 but /etc/passwd doesn't update —
# the code must detect this and emit an advisory, not claim success.
assert_pattern_present "$TUX_WSL" 'managed externally' \
    "20-terminal-ux/install.wsl.sh — advisory when account is LDAP/SSSD-managed"

assert_pattern_present "$TUX_MAC" 'CHSH_AUTO:-1' \
    "20-terminal-ux/install.mac.sh — CHSH_AUTO defaults to 1 (auto-on)"

assert_pattern_present "$TUX_MAC" 'sudo -n chsh -s' \
    "20-terminal-ux/install.mac.sh — attempts sudo chsh with cached ticket"

assert_pattern_present "$TUX_MAC" 'MDM/directory-managed' \
    "20-terminal-ux/install.mac.sh — advisory when directory is authoritative"

# chsh interactive fallback — sudo -n is a fast-path only; on a TTY we
# must also try plain `sudo chsh` so the user gets a single password
# prompt instead of an advisory when the upfront ticket has expired.
# This was the root cause of the failed chsh on crc (corporate WSL).
assert_pattern_present "$TUX_WSL" 'sudo chsh -s.*</dev/tty' \
    "20-terminal-ux/install.wsl.sh — interactive sudo chsh fallback via /dev/tty"

assert_pattern_present "$TUX_WSL" 'NON_INTERACTIVE:-0.*!=.*1' \
    "20-terminal-ux/install.wsl.sh — interactive fallback skipped in NON_INTERACTIVE"

assert_pattern_present "$TUX_MAC" 'sudo chsh -s.*</dev/tty' \
    "20-terminal-ux/install.mac.sh — interactive sudo chsh fallback via /dev/tty"

assert_pattern_present "$TUX_MAC" 'NON_INTERACTIVE:-0.*!=.*1' \
    "20-terminal-ux/install.mac.sh — interactive fallback skipped in NON_INTERACTIVE"

# atuin detection — must use `atuin status` exit code, NOT the stale
# ~/.local/share/atuin/session filesystem check. v18 stopped creating
# that file; filesystem-based detection gave a permanent false-negative
# advisory on logged-in machines (observed on ultron + crc + mac).
assert_pattern_present "$TUX_WSL" 'atuin status >/dev/null 2>&1' \
    "20-terminal-ux/install.wsl.sh — atuin detection uses 'atuin status' exit code"

assert_pattern_absent "$TUX_WSL" '\[ ! -f "\$HOME/\.local/share/atuin/session" \]' \
    "20-terminal-ux/install.wsl.sh — no longer checks ~/.local/share/atuin/session (v18 dropped it)"

assert_pattern_present "$TUX_MAC" 'atuin status >/dev/null 2>&1' \
    "20-terminal-ux/install.mac.sh — atuin detection uses 'atuin status' exit code"

assert_pattern_absent "$TUX_MAC" '\[ ! -f "\$HOME/\.local/share/atuin/session" \]' \
    "20-terminal-ux/install.mac.sh — no longer checks ~/.local/share/atuin/session (v18 dropped it)"

# Atuin login is now attempted inline when interactive — same design as
# CHSH_AUTO. Deferring to a post-hoc manual step was inconsistent with
# the auto-chsh/ngrok-passwordbox pattern shipped alongside it.
assert_pattern_present "$TUX_WSL" 'ATUIN_LOGIN_AUTO:-1' \
    "20-terminal-ux/install.wsl.sh — ATUIN_LOGIN_AUTO defaults to 1 (auto-on)"

assert_pattern_present "$TUX_WSL" 'atuin login </dev/tty' \
    "20-terminal-ux/install.wsl.sh — runs 'atuin login' inline via /dev/tty"

assert_pattern_present "$TUX_MAC" 'ATUIN_LOGIN_AUTO:-1' \
    "20-terminal-ux/install.mac.sh — ATUIN_LOGIN_AUTO defaults to 1 (auto-on)"

assert_pattern_present "$TUX_MAC" 'atuin login </dev/tty' \
    "20-terminal-ux/install.mac.sh — runs 'atuin login' inline via /dev/tty"

# TTY gate must test for controlling terminal via /dev/tty, NOT via
# `-t 1`. bootstrap.sh pipes each installer's stdout to `tee -a LOG`,
# which makes `-t 1` always false even when the human is still at the
# terminal. This silently disabled every interactive fallback (chsh
# prompt + atuin login) in actual runs. /dev/tty is the canonical ctty
# check — opens iff the process has a controlling terminal.
assert_pattern_present "$TUX_WSL" '_has_ctty\(\) \{' \
    "20-terminal-ux/install.wsl.sh — defines _has_ctty helper"

assert_pattern_present "$TUX_WSL" ': </dev/tty >/dev/null 2>&1' \
    "20-terminal-ux/install.wsl.sh — _has_ctty uses /dev/tty open test"

assert_pattern_absent "$TUX_WSL" '\[ -t 0 \] && \[ -t 1 \]' \
    "20-terminal-ux/install.wsl.sh — no longer gates on '-t 1' (broken under 'tee' pipe)"

assert_pattern_present "$TUX_MAC" '_has_ctty\(\) \{' \
    "20-terminal-ux/install.mac.sh — defines _has_ctty helper"

assert_pattern_present "$TUX_MAC" ': </dev/tty >/dev/null 2>&1' \
    "20-terminal-ux/install.mac.sh — _has_ctty uses /dev/tty open test"

assert_pattern_absent "$TUX_MAC" '\[ -t 0 \] && \[ -t 1 \]' \
    "20-terminal-ux/install.mac.sh — no longer gates on '-t 1' (broken under 'tee' pipe)"

# Issue 2 — secrets scaffold. bootstrap.sh must source lib/secrets.sh
# and call secrets_load AFTER log.sh, BEFORE the menu runs.
SECRETS_LIB="$ROOT/lib/secrets.sh"

assert_file_exists "$SECRETS_LIB" \
    "lib/secrets.sh — new helper in place"

assert_pattern_present "$BOOTSTRAP" 'source "\$HERE/lib/secrets.sh"' \
    "bootstrap.sh — sources lib/secrets.sh"

assert_pattern_present "$BOOTSTRAP" 'secrets_load' \
    "bootstrap.sh — calls secrets_load"

# Order check: secrets must be loaded before menu is sourced/run so the
# menu's secrets_has NGROK_AUTHTOKEN gate behaves correctly.
secrets_line=$(grep -n 'secrets_load' "$BOOTSTRAP" | head -1 | cut -d: -f1)
menu_line=$(grep -n 'source "\$HERE/lib/menu.sh"' "$BOOTSTRAP" | head -1 | cut -d: -f1)
if [[ -n "$secrets_line" && -n "$menu_line" ]] && [[ "$secrets_line" -lt "$menu_line" ]]; then
    pass "bootstrap.sh — secrets_load runs before menu is sourced (line $secrets_line < $menu_line)"
else
    fail "bootstrap.sh — secrets_load must run before menu (secrets=$secrets_line, menu=$menu_line)"
fi

# Menu: prompts for ngrok token only when selected and not already known.
assert_pattern_present "$MENU" 'secrets_has NGROK_AUTHTOKEN' \
    "lib/menu.sh — gates ngrok prompt on secrets_has"

assert_pattern_present "$MENU" 'passwordbox' \
    "lib/menu.sh — ngrok token uses --passwordbox (masked input)"

assert_pattern_present "$MENU" 'secrets_set NGROK_AUTHTOKEN' \
    "lib/menu.sh — persists ngrok token via secrets_set (NOT config.env)"

# secrets.env must NOT be written by _persist_menu_state (wrong file + mode).
assert_pattern_absent "$MENU" 'echo .export NGROK_AUTHTOKEN' \
    "lib/menu.sh — _persist_menu_state does NOT echo NGROK_AUTHTOKEN into config.env"

# Taxonomy check: secrets.sh header must document forbidden keys so a future
# contributor can't "just add GITHUB_TOKEN" without reading the rationale.
assert_pattern_present "$SECRETS_LIB" 'GITHUB_TOKEN.*gh auth' \
    "lib/secrets.sh — documents GITHUB_TOKEN belongs to gh auth, not here"

assert_pattern_present "$SECRETS_LIB" 'ATUIN_KEY.*atuin login' \
    "lib/secrets.sh — documents ATUIN_KEY belongs to atuin login, not here"

echo
echo "═══ 2026-04-23 : WSL PECL per-version build via PHP_PEAR_PHP_BIN ═══"

# Ondrej's /usr/bin/pecl is a single shell script bound to the current
# update-alternatives PHP default. Without PHP_PEAR_PHP_BIN + friends,
# every per-version `pecl install` silently built for PHP_DEFAULT.
# The fix lives in lib/pecl-install.sh (single source of truth) so
# install.wsl.sh + install-mssql-driver.sh share the same hardened
# implementation. These asserts inspect the lib directly.
LANG_WSL="$ROOT/topics/10-languages/install.wsl.sh"
PECL_LIB="$ROOT/lib/pecl-install.sh"
MSSQL="$ROOT/topics/60-web-stack/scripts/install-mssql-driver.sh"

assert_file_exists "$PECL_LIB" \
    "lib/pecl-install.sh — shared helper exists (single source of truth)"

# Both callers must source the lib. Duplicating the implementation is
# the exact class of bug that made ultron/crc regress differently.
assert_pattern_present "$LANG_WSL" 'source.*lib/pecl-install.sh' \
    "10-languages/install.wsl.sh — sources lib/pecl-install.sh"

assert_pattern_present "$MSSQL" 'source.*lib/pecl-install.sh' \
    "60-web-stack/install-mssql-driver.sh — sources lib/pecl-install.sh"

assert_pattern_present "$LANG_WSL" 'pecl_install_for_version_linux' \
    "10-languages/install.wsl.sh — calls pecl_install_for_version_linux from lib"

assert_pattern_present "$MSSQL" 'pecl_install_for_version_linux' \
    "60-web-stack/install-mssql-driver.sh — calls pecl_install_for_version_linux from lib"

# The 4 env vars — lib must set them all
assert_pattern_present "$PECL_LIB" 'PHP_PEAR_PHP_BIN="\$php_bin"' \
    "lib/pecl-install.sh — pecl pinned to target PHP via PHP_PEAR_PHP_BIN"

# PEAR does NOT honor PHP_PEAR_PHPIZE_BIN (grep /usr/share/php/PEAR/Config.php).
# Real mechanism: PEAR prepends bin_dir to PATH, then looks up `phpize`
# via PATH. Overriding bin_dir via PHP_PEAR_BIN_DIR to a scratch dir full
# of per-version symlinks is the canonical way to pin the toolchain.
assert_pattern_present "$PECL_LIB" 'PHP_PEAR_BIN_DIR="\$tmpbin"' \
    "10-languages/install.wsl.sh — PHP_PEAR_BIN_DIR points to scratch shim dir"

# CRITICAL: without isolated metadata_dir, each per-version `pecl install -f`
# first UNINSTALLS the previously-registered version — deleting the .so
# from a different PHP's ABI dir. Observed in ultron 15:48 run: 8.3
# installs landed, then 8.5's install -f deleted them. Isolated registry
# per call makes each install see an empty registry.
assert_pattern_present "$PECL_LIB" 'PHP_PEAR_METADATA_DIR="\$tmpmeta"' \
    "10-languages/install.wsl.sh — PHP_PEAR_METADATA_DIR isolates PEAR registry per call"

assert_pattern_present "$PECL_LIB" 'tmpmeta="\$\(mktemp -d' \
    "10-languages/install.wsl.sh — allocates tmpmeta scratch dir"

assert_pattern_present "$PECL_LIB" "trap 'sudo rm -rf \"\\\$tmpbin\" \"\\\$tmpmeta\"" \
    "10-languages/install.wsl.sh — trap cleans both tmpbin AND tmpmeta with sudo"

assert_pattern_present "$PECL_LIB" "'sudo rm.*2>/dev/null \|\| true' RETURN" \
    "10-languages/install.wsl.sh — trap absorbs rm errors (else set -e aborts the loop)"

assert_pattern_present "$PECL_LIB" 'ln -s "\$phpize_bin"' \
    "10-languages/install.wsl.sh — scratch dir has phpize symlink → phpize\${ver}"

assert_pattern_present "$PECL_LIB" 'ln -s "\$php_config_bin"' \
    "10-languages/install.wsl.sh — scratch dir has php-config symlink → php-config\${ver}"

# PHP_PEAR_EXTENSION_DIR overrides the .so install target — otherwise
# pecl installs into ext_dir from config (= default PHP's ABI dir).
assert_pattern_present "$PECL_LIB" 'PHP_PEAR_EXTENSION_DIR="\$target_ext_dir"' \
    "10-languages/install.wsl.sh — .so target dir pinned via PHP_PEAR_EXTENSION_DIR"

# (superseded by trap-cleans-both assertion above — removing the
# single-dir trap check because current code cleans both scratch dirs)

# `sudo env KEY=VAL cmd` survives sudoers env_reset; `sudo -E` does not.
assert_pattern_present "$PECL_LIB" 'sudo env \\' \
    "10-languages/install.wsl.sh — uses 'sudo env' (bulletproof vs env_reset)"

# PHP_PEAR_PHPIZE_BIN is a dead env var — PEAR does not read it anywhere
# (verified in pecl-version-pinning.test.sh by grepping Config.php).
# The earliest version of this fix used it and failed silently on the
# actual Ondrej install. Lock that out.
assert_pattern_absent "$PECL_LIB" 'PHP_PEAR_PHPIZE_BIN' \
    "10-languages/install.wsl.sh — does NOT use PHP_PEAR_PHPIZE_BIN (dead env var; PEAR ignores)"

# The .so-existence post-check is the source of truth — file-based
# idempotency, not the ambiguous pecl exit code.
assert_pattern_present "$PECL_LIB" 'php_config_bin.*phpapi' \
    "10-languages/install.wsl.sh — resolves PHP ABI via php-config --phpapi"

assert_pattern_present "$PECL_LIB" '\[\[ ! -f "\$so_path" \]\]' \
    "10-languages/install.wsl.sh — verifies .so file actually landed at expected path"

# The previous "silent failure" anti-pattern: redirecting stderr to
# /dev/null and emitting only "(check logs manually)" meant the user
# had no way to diagnose why. The new code prints the last lines of
# pecl output on failure.
assert_pattern_present "$PECL_LIB" 'tail -6' \
    "10-languages/install.wsl.sh — surfaces last 6 lines of pecl output on failure"

assert_pattern_absent "$PECL_LIB" 'check logs manually' \
    "10-languages/install.wsl.sh — no longer points users at non-existent 'logs'"

echo
echo "═══ 2026-04-23 : stale \$SHELL + tmux SHELL detection (crc regression) ═══"

# Observed on crc: chsh succeeded (getent passwd = /usr/bin/zsh) but the
# running ssh/mosh session still had $SHELL=/bin/bash cached from before
# chsh. tmux server, started under that stale env, then propagated
# SHELL=/bin/bash to every new pane → status-position wrong, Moshi
# misdetected sessions, subprocesses opened the wrong shell.
#
# Static tests that the 2 detection blocks exist in both installers.
# The actual runtime behavior is hard to unit-test (requires a session
# with a real $SHELL mismatch + a running tmux server) — the static
# asserts ensure the code is present and anyone refactoring gets told
# before they silently drop the detection.

# --- $SHELL vs /etc/passwd mismatch detection (WSL) ---
assert_pattern_present "$TUX_WSL" '\$SHELL.*!=.*passwd_shell|passwd_shell.*!=.*\$SHELL' \
    "20-terminal-ux/install.wsl.sh — detects \$SHELL ≠ /etc/passwd mismatch"

assert_pattern_present "$TUX_WSL" 'exit this ssh/mosh session' \
    "20-terminal-ux/install.wsl.sh — advisory instructs session reconnect (not just 'exec zsh')"

assert_pattern_present "$TUX_WSL" 'tmux kill-server' \
    "20-terminal-ux/install.wsl.sh — advisory mentions tmux kill-server for stale server"

# --- tmux server stale SHELL detection (WSL) ---
assert_pattern_present "$TUX_WSL" 'tmux show-environment -g SHELL' \
    "20-terminal-ux/install.wsl.sh — probes tmux server's cached SHELL"

# --- same for Mac via dscl ---
assert_pattern_present "$TUX_MAC" 'UserShell.*!=.*\$SHELL|\$SHELL.*!=.*UserShell|passwd_shell.*!=.*\$SHELL|\$SHELL.*!=.*passwd_shell' \
    "20-terminal-ux/install.mac.sh — detects \$SHELL ≠ dscl UserShell mismatch"

assert_pattern_present "$TUX_MAC" 'exit this ssh/mosh session' \
    "20-terminal-ux/install.mac.sh — advisory instructs session reconnect"

assert_pattern_present "$TUX_MAC" 'tmux kill-server' \
    "20-terminal-ux/install.mac.sh — advisory mentions tmux kill-server"

assert_pattern_present "$TUX_MAC" 'tmux show-environment -g SHELL' \
    "20-terminal-ux/install.mac.sh — probes tmux server's cached SHELL"

# Advisory text must NOT claim `exec zsh` is a sufficient fix — that
# only changes the running process, not \$SHELL, so tmux/mosh etc still
# inherit the stale value. The original "exec zsh" hint is still fine
# as a LOCAL prompt fix as long as the advisory ALSO explains the full
# fix via reconnect. We assert the reconnect text is present; we don't
# forbid 'exec zsh' because it's still a useful convenience.

echo
summary
