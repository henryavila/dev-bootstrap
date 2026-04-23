#!/usr/bin/env bash
# 10-languages (mac): Node via fnm (brew), PHP multi-version (brew), Composer, Python.
#
# Mac multi-PHP specifics:
#   - brew's `php@X.Y` formulas are keg-only (don't auto-link). We install
#     every version in PHP_VERSIONS, then `brew link --force --overwrite`
#     ONLY for PHP_DEFAULT so `php` on PATH resolves to the default. Other
#     versions stay invokable as `php8.X` via their full keg path.
#   - Built-in extensions in the brew formula cover most of the apt baseline
#     (gd, intl, curl, etc. — no per-extension formula). We still run the
#     PECL loop to install extras that aren't bundled (igbinary, imagick,
#     mongodb, redis).
#   - Composer lives as a separate formula; it picks up whichever `php` is
#     currently linked — i.e. our default.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

: "${BREW_BIN:?BREW_BIN not set — run through bootstrap.sh}"
: "${BREW_PREFIX:?BREW_PREFIX not set}"

# Tracks formulas that brew_install_if_missing could not install. Read
# downstream (PECL loop) to skip extensions whose build deps are missing,
# and surfaced as a followup at run end so the user sees exactly what
# needs manual attention.
BREW_INSTALL_FAILED=()

brew_install_if_missing() {
    local pkg="$1"
    local strict="${2:-strict}"   # "strict" aborts on failure; "soft" continues

    if "$BREW_BIN" list --formula "$pkg" >/dev/null 2>&1; then
        ok "$pkg already installed"
        return 0
    fi

    info "brew install $pkg"
    if "$BREW_BIN" install "$pkg"; then
        return 0
    fi

    # First attempt failed. Three retry tiers, in order of how much
    # they bypass safety:
    #
    # Tier 1 — refresh + clean download cache + retry as-is.
    #   Fixes: stale formula (brew update), corrupt cached tarball
    #   (rm -f $cache_path), transient mirror hiccup (re-fetch).
    #
    # Tier 2 — same as 1 but explicit --build-from-source.
    #   On non-standard HOMEBREW_PREFIX, brew should fall through to
    #   source automatically. Belt-and-suspenders ensures we don't
    #   spend the retry re-trying a bottle that can't relocate.
    #
    # Tier 3 — --HEAD: clones the upstream git repo and bypasses the
    #   tarball download entirely. Fixes the case where upstream
    #   re-tagged a release: formula's expected SHA256 no longer
    #   matches the served tarball, regardless of how many `brew
    #   update` we run, because the mirror's tarball is what changed.
    #   ImageMagick is the canonical example — it re-tags 7.1.x
    #   patches every few weeks. Trade-off: we build whatever's on
    #   upstream main RIGHT NOW, which may be ahead of the tagged
    #   release. For ImageMagick (stable API since 2016), low risk.
    #
    # Bottle-unavailable-on-non-standard-prefix (HOMEBREW_PREFIX !=
    # /opt/homebrew, e.g. brew on /Volumes/External) is the root cause
    # forcing source builds. None of these tiers fix that — but they
    # together cover every realistic checksum/source-build failure.

    warn "brew install $pkg failed — Tier 1: refresh formula cache + clear download cache + retry"
    "$BREW_BIN" update >/dev/null 2>&1 || true
    "$BREW_BIN" cleanup "$pkg" >/dev/null 2>&1 || true
    cache_path="$("$BREW_BIN" --cache "$pkg" 2>/dev/null || true)"
    [[ -n "$cache_path" && -e "$cache_path" ]] && rm -f "$cache_path"
    if "$BREW_BIN" install "$pkg"; then
        ok "$pkg installed after Tier 1 retry"
        return 0
    fi

    warn "$pkg Tier 1 failed — Tier 2: explicit --build-from-source"
    if "$BREW_BIN" install --build-from-source "$pkg"; then
        ok "$pkg installed after Tier 2 (--build-from-source)"
        return 0
    fi

    # Check formula has a HEAD spec before trying — not all do.
    # `brew info --json=v2` reports `urls.head.url` if defined.
    has_head="$("$BREW_BIN" info --json=v2 "$pkg" 2>/dev/null \
        | grep -o '"head"' | head -1)"
    if [[ -n "$has_head" ]]; then
        warn "$pkg Tier 2 failed — Tier 3: --HEAD (bypasses tarball checksum, builds from upstream git)"
        if "$BREW_BIN" install --HEAD "$pkg"; then
            ok "$pkg installed via --HEAD after standard install failed (built from upstream git)"
            return 0
        fi
    else
        warn "$pkg has no HEAD spec in formula — skipping Tier 3"
    fi

    BREW_INSTALL_FAILED+=("$pkg")
    if [[ "$strict" == "soft" ]]; then
        warn "brew install $pkg exhausted all retry tiers — continuing (build deps only, not critical)"
        return 1
    else
        fail "brew install $pkg exhausted all retry tiers — aborting"
        return 1
    fi
}

# ─── fnm + Node ────────────────────────────────────────────────────────
brew_install_if_missing fnm

eval "$("$BREW_PREFIX/bin/fnm" env)"
if "$BREW_PREFIX/bin/fnm" list 2>/dev/null | grep -qE '\bv[0-9]+\.[0-9]+\.[0-9]+'; then
    ok "Node already installed via fnm ($("$BREW_PREFIX/bin/fnm" current 2>/dev/null || echo '?'))"
else
    info "fnm install --lts"
    "$BREW_PREFIX/bin/fnm" install --lts
    default_ver="$("$BREW_PREFIX/bin/fnm" list | awk '/^\s*v[0-9]/ {print $NF}' | tail -1 || true)"
    [[ -n "$default_ver" ]] && "$BREW_PREFIX/bin/fnm" default "$default_ver" || true
fi

# ─── PHP versions (multi) ──────────────────────────────────────────────
PHP_VERSIONS_FILE="$HERE/data/php-versions.conf"
if [[ -z "${PHP_VERSIONS:-}" ]]; then
    PHP_VERSIONS="$(grep -vE '^\s*(#|$)' "$PHP_VERSIONS_FILE" | xargs)"
    info "PHP_VERSIONS unset — defaulting to all supported ($PHP_VERSIONS)"
fi
PHP_DEFAULT="${PHP_DEFAULT:-$(echo "$PHP_VERSIONS" | tr ' ' '\n' | sort -V | tail -1)}"
info "PHP versions to install: $PHP_VERSIONS (default: $PHP_DEFAULT)"
export PHP_DEFAULT

for ver in $PHP_VERSIONS; do
    brew_install_if_missing "php@${ver}"
done

# Link the default, unlink all others so `php` on PATH is unambiguous
info "linking PHP default → php@${PHP_DEFAULT}"
for ver in $PHP_VERSIONS; do
    if [[ "$ver" != "$PHP_DEFAULT" ]]; then
        "$BREW_BIN" unlink "php@${ver}" >/dev/null 2>&1 || true
    fi
done
"$BREW_BIN" link --force --overwrite "php@${PHP_DEFAULT}" >/dev/null 2>&1 || \
    warn "brew link php@${PHP_DEFAULT} failed — check \`command -v php\`"
ok "PHP CLI default: $(php -r 'echo PHP_VERSION;' 2>/dev/null || echo '?')"

# ─── PECL build deps (Mac: brew formulas from the 3rd colon field) ────
# bash 3.2 (macOS default) has no `mapfile`. while-read populates
# the array one line at a time — portable across bash 3.2 + 4/5.
PECL_LINES=()
while IFS= read -r _line; do
    PECL_LINES+=("$_line")
done < <(grep -vE '^\s*(#|$)' "$HERE/data/php-extensions-pecl.txt")
unset _line

mac_build_deps=(pkg-config autoconf)
for line in "${PECL_LINES[@]}"; do
    # line format: ext[:linux-deps[:mac-deps]]
    IFS=':' read -r _ _ mac_deps <<< "$line"
    if [[ -n "${mac_deps:-}" ]]; then
        # shellcheck disable=SC2206
        mac_build_deps+=($mac_deps)
    fi
done
# Install build deps in "soft" mode — if one (typically imagemagick, which
# needs source builds on non-standard HOMEBREW_PREFIX and hits upstream
# checksum drift) fails, we don't want to abort the whole topic. Downstream
# PECL loop will skip any extension whose build deps didn't install.
for d in $(printf '%s\n' "${mac_build_deps[@]}" | sort -u); do
    brew_install_if_missing "$d" soft || true
done

# Remember which build deps are missing so the PECL loop can skip their
# dependent extensions cleanly (vs. failing per-version with confusing
# error messages deep in the pecl output).
_is_brew_missing() {
    local p="$1"
    for q in "${BREW_INSTALL_FAILED[@]+"${BREW_INSTALL_FAILED[@]}"}"; do
        [[ "$q" == "$p" ]] && return 0
    done
    return 1
}

# ─── PECL extensions (per version) ────────────────────────────────────
# Each keg-only php@X.Y has its own pecl/phpize at $BREW_PREFIX/opt/php@X.Y/bin.
# Using the full path binds the build to the right PHP ABI.
pecl_install_for_mac() {
    local ver="$1" ext="$2"
    local prefix="$BREW_PREFIX/opt/php@${ver}"
    local pecl_bin="$prefix/bin/pecl"
    local php_bin="$prefix/bin/php"

    # Brew separates `etc` from the cellar — config files live OUTSIDE
    # the per-version opt symlink. PHP scans this dir for additional
    # .ini files (verifiable via `php --ini`):
    #   $BREW_PREFIX/etc/php/<VER>/conf.d/  ← correct
    #   $prefix/etc/php/<VER>/conf.d/       ← WRONG (under opt/, never scanned)
    # An older version of this function used the wrong path; the orphan
    # cleanup loop above sweeps any leftovers from that era.
    local ini_dir="$BREW_PREFIX/etc/php/${ver}/conf.d"
    local ini_file="${ini_dir}/ext-${ext}.ini"

    [[ ! -x "$pecl_bin" ]] && { warn "$pecl_bin not found — skipping ext=$ext for php@${ver}"; return; }

    # Inline helper: write conf.d ini only if absent. Idempotent.
    _ensure_ini() {
        mkdir -p "$ini_dir"
        if [[ ! -f "$ini_file" ]]; then
            echo "extension=${ext}.so" > "$ini_file"
        fi
    }

    # ── Detection paths (in order; first match returns) ──────────────

    # Path 1: extension already LOADED in PHP — fully done, skip silently.
    if "$php_bin" -m 2>/dev/null | grep -qiE "^${ext}\$|^${ext//pdo_/PDO_}\$"; then
        _ensure_ini   # belt-and-suspenders: ini in right path even if PHP
                      # is loading it via some other mechanism
        ok "php@${ver}: $ext already loaded"
        return 0
    fi

    # Path 2: pecl already BUILT the .so but PHP is not loading it.
    # Almost always the ini-path migration scenario — pecl install ran
    # under the old wrong-path code, the .so is on disk and registered
    # with pecl, but our conf.d ini was orphaned. Just write the ini
    # in the right place; PHP picks it up next launch.
    if "$pecl_bin" list 2>/dev/null | grep -qE "^${ext}[[:space:]]"; then
        info "php@${ver}: $ext already built via pecl — writing ini at correct path"
        _ensure_ini
        ok "php@${ver}: $ext enabled (existing build + correct ini)"
        return 0
    fi

    # Path 3: genuine first install. Capture output for diagnostics —
    # the previous `>/dev/null 2>&1` made every failure indistinguishable
    # ("failed — continuing" with no clue why). Now we keep the output,
    # only show it on failure, and special-case "already installed"
    # which pecl emits as exit-1 even though it is a no-op (handled
    # already by Path 2 above; this is just defense in depth).
    info "php@${ver}: pecl install $ext"
    local pecl_out pecl_rc
    pecl_out=$(printf '\n' | "$pecl_bin" install "$ext" 2>&1) ; pecl_rc=$?

    if [[ "$pecl_rc" -ne 0 ]]; then
        if printf '%s' "$pecl_out" | grep -qiE "already installed|is already enabled"; then
            info "php@${ver}: pecl reports $ext already installed — writing ini"
            _ensure_ini
            ok "php@${ver}: $ext enabled"
            return 0
        fi
        warn "php@${ver}: pecl install $ext failed (exit $pecl_rc) — continuing"
        printf '%s\n' "$pecl_out" | tail -8 | sed 's/^/    /' >&2
        return 0
    fi

    _ensure_ini
    ok "php@${ver}: $ext enabled"
}

# ─── Migration: clean up orphan inis from old wrong-path bug ────────
# Previous versions of pecl_install_for_mac wrote conf.d ini files
# under $BREW_PREFIX/opt/php@X.Y/etc/php/X.Y/conf.d/ — a path PHP
# never scans (etc/ is outside the cellar/opt symlink in brew). The
# files are harmless (ignored by PHP) but leave dead bytes on disk
# and confuse anyone inspecting the install. Sweep them on first run
# with the corrected path.
for ver in $PHP_VERSIONS; do
    orphan_dir="$BREW_PREFIX/opt/php@${ver}/etc/php/${ver}/conf.d"
    if [[ -d "$orphan_dir" ]]; then
        for orphan in "$orphan_dir"/ext-*.ini; do
            [[ -f "$orphan" ]] || continue
            info "removing orphan ini from old wrong path: $orphan"
            rm -f "$orphan"
        done
        # Try removing the now-empty dir tree (rmdir bails if non-empty,
        # which is correct — leaves anything we did not author intact).
        rmdir "$orphan_dir" 2>/dev/null || true
        rmdir "$BREW_PREFIX/opt/php@${ver}/etc/php/${ver}" 2>/dev/null || true
        rmdir "$BREW_PREFIX/opt/php@${ver}/etc/php" 2>/dev/null || true
        rmdir "$BREW_PREFIX/opt/php@${ver}/etc" 2>/dev/null || true
    fi
done

for line in "${PECL_LINES[@]}"; do
    IFS=':' read -r ext _ mac_deps_line <<< "$line"

    # If any Mac build dep for this extension failed to install earlier,
    # skip the whole extension (every PHP version would fail the same way)
    # and surface a single followup instead of N per-version errors.
    skip_ext=""
    if [[ -n "${mac_deps_line:-}" ]]; then
        # shellcheck disable=SC2206
        _deps=($mac_deps_line)
        for dep in "${_deps[@]}"; do
            if _is_brew_missing "$dep"; then
                skip_ext="$dep"
                break
            fi
        done
    fi
    if [[ -n "$skip_ext" ]]; then
        followup manual \
"php extension '$ext' skipped — build dependency '$skip_ext' could
  not be installed via brew (likely a bottle/source-build issue on a
  non-standard HOMEBREW_PREFIX such as /Volumes/External).

  To finish manually:
    brew update
    brew install --build-from-source $skip_ext     # or move brew to /opt/homebrew
  Then for each PHP version (${PHP_VERSIONS}):
    printf '\n' | \$(brew --prefix)/opt/php@<VER>/bin/pecl install -f $ext"
        continue
    fi

    for ver in $PHP_VERSIONS; do
        pecl_install_for_mac "$ver" "$ext"
    done
done

# ─── Composer + Python ───────────────────────────────────────────────
brew_install_if_missing composer
brew_install_if_missing python@3.13

# ─── Brew install failure summary ────────────────────────────────────
if [[ "${#BREW_INSTALL_FAILED[@]}" -gt 0 ]]; then
    followup manual \
"brew failed to install these formulas (topic 10-languages):
  ${BREW_INSTALL_FAILED[*]}

  Most common cause on this machine: HOMEBREW_PREFIX is non-standard
  (bottles can't be used so brew builds from source, and upstream
  tarball checksums occasionally drift between formula updates).

  Remediation:
    brew update && brew install <formula>
  Or, for a permanent fix, relocate brew to /opt/homebrew (arm64) or
  /usr/local (x86_64) — bottle-based installs will work without
  falling back to source builds."
fi

ok "10-languages done — PHP default: $PHP_DEFAULT"
