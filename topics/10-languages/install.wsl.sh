#!/usr/bin/env bash
# 10-languages (WSL): Node (fnm), PHP multi-version (ondrej PPA), Composer, Python.
#
# Multi-PHP flow:
#   1. Read PHP_VERSIONS env var (set by the menu or pre-seeded). Default: all
#      versions listed in data/php-versions.conf.
#   2. For each version, apt-install: php<V>, php<V>-fpm + every extension
#      listed in data/php-extensions-apt.txt (as `php<V>-<name>`).
#   3. For each version, PECL-install every extension in data/php-extensions-pecl.txt
#      using that version's phpize/pecl so each PHP has its own ABI-matched .so.
#   4. PHP default (update-alternatives) = last sort -V of PHP_VERSIONS, so
#      adding a new version to data/php-versions.conf auto-promotes it when
#      the menu picks it up. Composer is installed once, bound to the default.
#
# To add a new version (e.g. 8.6 when released):
#   - Add "8.6" to data/php-versions.conf.
#   - Nothing else: every install.*.sh, nginx template, and menu reads the file.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

# ─── fnm + Node ────────────────────────────────────────────────────────
if ! command -v fnm >/dev/null 2>&1 && [[ ! -x "$HOME/.local/share/fnm/fnm" ]]; then
    info "installing fnm"
    curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
else
    ok "fnm already installed"
fi

if [[ -x "$HOME/.local/share/fnm/fnm" ]]; then
    export PATH="$HOME/.local/share/fnm:$PATH"
fi
if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env)"
    if fnm list 2>/dev/null | grep -qE '\bv[0-9]+\.[0-9]+\.[0-9]+'; then
        ok "Node already installed via fnm ($(fnm current 2>/dev/null || echo '?'))"
    else
        info "installing Node LTS via fnm"
        fnm install --lts
        latest="$(fnm list | awk '/^\s*v[0-9]/ {print $NF}' | tail -1)"
        [[ -n "$latest" ]] && fnm default "$latest" || true
    fi
fi

# ─── PHP versions (multi) ──────────────────────────────────────────────
# PHP_VERSIONS can come from env (menu or automation). If unset, install all
# supported versions from data/php-versions.conf.
PHP_VERSIONS_FILE="$HERE/data/php-versions.conf"
if [[ -z "${PHP_VERSIONS:-}" ]]; then
    PHP_VERSIONS="$(grep -vE '^\s*(#|$)' "$PHP_VERSIONS_FILE" | xargs)"
    info "PHP_VERSIONS unset — defaulting to all supported ($PHP_VERSIONS)"
fi

# PHP default = highest version (version-sorted, last)
PHP_DEFAULT="${PHP_DEFAULT:-$(echo "$PHP_VERSIONS" | tr ' ' '\n' | sort -V | tail -1)}"
info "PHP versions to install: $PHP_VERSIONS (default: $PHP_DEFAULT)"
export PHP_DEFAULT

# Ensure ondrej/php PPA is enabled (once — all versions share it)
if ! grep -Rq 'ondrej/php' /etc/apt/sources.list.d/ 2>/dev/null; then
    info "enabling ondrej/php PPA"
    sudo add-apt-repository -y ppa:ondrej/php
    sudo apt-get update -qq
fi

# Read extension lists once (while-read for bash 3.2 compat — see Mac notes)
APT_EXTS=()
while IFS= read -r _line; do
    APT_EXTS+=("$_line")
done < <(grep -vE '^\s*(#|$)' "$HERE/data/php-extensions-apt.txt")
unset _line

install_php_version() {
    local ver="$1"
    local pkgs=("php${ver}" "php${ver}-cli" "php${ver}-common" "php${ver}-fpm")
    for ext in "${APT_EXTS[@]}"; do
        pkgs+=("php${ver}-${ext}")
    done

    local missing=()
    for p in "${pkgs[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done

    if [[ "${#missing[@]}" -eq 0 ]]; then
        ok "PHP $ver and all baseline extensions already installed"
        return 0
    fi

    info "apt install PHP $ver + extensions (${#missing[@]} pkgs)"
    sudo apt-get install -y -qq "${missing[@]}"
    ok "PHP $ver installed"
}

for ver in $PHP_VERSIONS; do
    install_php_version "$ver"
done

# ─── PHP default via update-alternatives ──────────────────────────────
# The `php` symlink (and phar/phpize/pecl helpers) follows the alternatives
# group. Setting one auto-sets the rest. Safe to run on every bootstrap —
# noop if already pointing at the desired version.
info "setting PHP default = $PHP_DEFAULT"
for bin in php phar phar.phar phpize php-config; do
    target="/usr/bin/${bin}${PHP_DEFAULT}"
    if [[ -x "$target" ]]; then
        sudo update-alternatives --set "$bin" "$target" >/dev/null 2>&1 || true
    fi
done
ok "PHP CLI default: $(php -r 'echo PHP_VERSION;' 2>/dev/null || echo '?')"

# ─── PECL extensions (per version) ────────────────────────────────────
# Each major PHP has an ABI-distinct .so; we install the same extension
# once per version of PHP_VERSIONS. Build deps in the second colon-column
# of data/php-extensions-pecl.txt apply to all versions (installed once).
info "installing PECL extensions for each PHP version"

PECL_LINES=()
while IFS= read -r _line; do
    PECL_LINES+=("$_line")
done < <(grep -vE '^\s*(#|$)' "$HERE/data/php-extensions-pecl.txt")
unset _line

# Collect the union of linux build deps across all pecl lines
pecl_build_deps=()
for line in "${PECL_LINES[@]}"; do
    # line format: ext[:linux-deps[:mac-deps]]
    IFS=':' read -r _ linux_deps _ <<< "$line"
    if [[ -n "$linux_deps" ]]; then
        # shellcheck disable=SC2206
        pecl_build_deps+=($linux_deps)
    fi
done
# unixodbc-dev not in PECL list but needed for MSSQL add-on later; leave out here.

# Always need the dev toolchain for PECL builds. Install once.
core_build_deps=(build-essential pkg-config autoconf)
combined_deps=("${core_build_deps[@]}" "${pecl_build_deps[@]+"${pecl_build_deps[@]}"}")
missing_deps=()
for p in "${combined_deps[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing_deps+=("$p")
done
if [[ "${#missing_deps[@]}" -gt 0 ]]; then
    info "installing PECL build deps: ${missing_deps[*]}"
    sudo apt-get install -y -qq "${missing_deps[@]}"
fi

# Also need per-version dev headers to compile .so for that PHP
for ver in $PHP_VERSIONS; do
    if ! dpkg -s "php${ver}-dev" >/dev/null 2>&1; then
        info "installing php${ver}-dev (headers for PECL build)"
        sudo apt-get install -y -qq "php${ver}-dev"
    fi
done

pecl_install_for_version() {
    local ver="$1" ext="$2"

    # ondrej does NOT ship per-version pecl binaries on Ubuntu — only
    # phpize${ver} and php-config${ver}. There's a single /usr/bin/pecl
    # shell script that launches under whichever PHP `update-alternatives`
    # currently points to (normally the highest installed version, i.e.
    # PHP_DEFAULT). Without intervention, every per-version install call
    # silently targets the DEFAULT version — the builds either fail or
    # land in the wrong ABI dir, and `php${ver} -m` keeps returning
    # "not loaded" for non-default versions on every subsequent run.
    #
    # Fix: take FOUR complementary steps, each targeting a different
    # stage of the pecl → pear → build → registry pipeline:
    #
    #   1. PHP_PEAR_PHP_BIN  — pins /usr/bin/pecl's `exec` line to the
    #                          target PHP binary. (Shell-level.)
    #   2. PHP_PEAR_BIN_DIR  — PEAR's Builder.php prepends this dir to
    #                          PATH before running `phpize` / `php-config`
    #                          via PATH lookup. We point it at a scratch
    #                          dir containing symlinks named `phpize` and
    #                          `php-config` that resolve to the target
    #                          version's binaries. (PEAR-level.)
    #   3. PHP_PEAR_EXTENSION_DIR — overrides PEAR's ext_dir config so
    #                          the .so is INSTALLED into the correct ABI
    #                          directory (/usr/lib/php/<api>/) instead of
    #                          the default-PHP's dir. (Installer-level.)
    #   4. PHP_PEAR_METADATA_DIR — isolates the PEAR registry per call.
    #                          Without this, the global registry at
    #                          /usr/share/php/.registry/ tracks a single
    #                          install per package; the NEXT per-version
    #                          `pecl install -f` first uninstalls the
    #                          previously-registered one — deleting the
    #                          .so from a DIFFERENT PHP's ABI dir.
    #                          Observed concretely in ultron run 15:48:
    #                          8.3 installs landed correctly, then 8.5
    #                          reinstalls deleted 8.3's .so files before
    #                          building their own. (Registry-level.)
    #
    # Step 2 is what actually controls the ABI the build targets. PEAR
    # uses:
    #     $php_prefix + "phpize" + $php_suffix
    # to locate phpize; both config keys default to empty, so it just
    # runs "phpize" via PATH. Our shim dir — prepended by PHP_PEAR_BIN_DIR
    # — shadows the alternatives-managed phpize symlink.
    #
    # Why not just set $php_suffix via PEAR config? `pecl config-set`
    # writes to a shared .pearrc file; changing it per-version is racy
    # and leaves the system in a weird state if bootstrap is interrupted.
    # The scratch-dir-with-symlinks approach is per-invocation and
    # self-cleaning.
    #
    # `sudo env KEY=VAL cmd` (not `sudo -E`) is bulletproof under the
    # default sudoers `env_reset` policy.
    local pecl_bin="/usr/bin/pecl"
    local php_bin="/usr/bin/php${ver}"
    local phpize_bin="/usr/bin/phpize${ver}"
    local php_config_bin="/usr/bin/php-config${ver}"

    for _b in "$pecl_bin" "$php_bin" "$phpize_bin" "$php_config_bin"; do
        if [[ ! -x "$_b" ]]; then
            warn "PHP $ver: required binary $_b missing — skipping $ext"
            return 0
        fi
    done

    # Resolve the ABI API number so we can (a) point PHP_PEAR_EXTENSION_DIR
    # at the right install target, and (b) verify post-install that the
    # .so actually landed there. Filesystem > `php -m` — the latter also
    # depends on phpenmod state, the former is authoritative.
    local api
    api="$("$php_config_bin" --phpapi 2>/dev/null)"
    if [[ -z "$api" ]]; then
        warn "PHP $ver: could not resolve PHP API from $php_config_bin — skipping $ext"
        return 0
    fi
    local target_ext_dir="/usr/lib/php/${api}"
    local so_path="${target_ext_dir}/${ext}.so"

    # Already loaded? Fast path — nothing to do.
    if php${ver} -m 2>/dev/null | grep -qiE "^${ext}\$|^${ext//pdo_/PDO_}\$"; then
        ok "PHP $ver: $ext already loaded"
        return 0
    fi

    # Per-invocation scratch state. TWO directories, both under mktemp:
    #
    #   $tmpbin   — PATH shim dir with phpize/php-config/php symlinks
    #               pointing at the per-version binaries. PEAR prepends
    #               this to PATH (via PHP_PEAR_BIN_DIR override) so
    #               bare `phpize` + `php-config` resolve here.
    #   $tmpmeta  — isolated PEAR registry dir. CRITICAL: without this,
    #               pecl's global registry at /usr/share/php/.registry/
    #               tracks "igbinary is installed at <last-target-dir>"
    #               — and the next per-version `pecl install -f` would
    #               first UNINSTALL the previously registered one,
    #               DELETING the .so from a different PHP's ABI dir.
    #               Isolated metadata per call means each invocation
    #               sees an empty registry and only ever touches its
    #               own target_ext_dir.
    #
    # Both dirs cleaned via `trap RETURN` even if pecl is killed.
    local tmpbin tmpmeta
    tmpbin="$(mktemp -d -t dev-bootstrap-pecl-bin.XXXXXX)"
    tmpmeta="$(mktemp -d -t dev-bootstrap-pecl-meta.XXXXXX)"
    ln -s "$phpize_bin"      "$tmpbin/phpize"
    ln -s "$php_config_bin"  "$tmpbin/php-config"
    ln -s "$php_bin"         "$tmpbin/php"
    trap 'rm -rf "$tmpbin" "$tmpmeta"' RETURN

    info "PHP $ver: pecl install $ext (target: $so_path)"
    # `-f` forces rebuild when pecl's internal cache thinks the ext is
    # already installed. With isolated $tmpmeta the registry starts
    # empty each call, so `-f` is defensive here (handles the case
    # where /tmp/pear/cache already has a built tarball from a prior
    # run) without the cross-version uninstall side-effect.
    # `printf '\n'` accepts default prompts (imagick asks about
    # ImageMagick autodetect).
    local pecl_out="" pecl_rc=0
    pecl_out=$(printf '\n' | sudo env \
        PHP_PEAR_PHP_BIN="$php_bin" \
        PHP_PEAR_BIN_DIR="$tmpbin" \
        PHP_PEAR_METADATA_DIR="$tmpmeta" \
        PHP_PEAR_EXTENSION_DIR="$target_ext_dir" \
        "$pecl_bin" install -f "$ext" 2>&1) || pecl_rc=$?

    # Two-signal failure check: non-zero exit OR expected .so did not
    # appear. The file check catches the "pecl silently installed into
    # the wrong ABI dir" class of failure — which is exactly the bug we
    # are fixing. If the env vars are set but something else goes wrong
    # (missing build dep, network, etc.), the file won't exist either.
    if [[ "$pecl_rc" -ne 0 ]] || [[ ! -f "$so_path" ]]; then
        warn "PHP $ver: pecl install $ext failed (exit=$pecl_rc, .so not at $so_path)"
        # Show tail of the real output so the user can act on the real
        # error (missing dep, compile failure, network, etc.) instead of
        # a dead-end advisory on the next run.
        if [[ -n "$pecl_out" ]]; then
            printf '%s\n' "$pecl_out" | tail -6 | sed 's/^/      /' >&2
        fi
        return 0
    fi

    # Enable the .so. Priority 20 matches Debian convention (after core).
    local ini_dir="/etc/php/${ver}/mods-available"
    local ini_file="${ini_dir}/${ext}.ini"
    if [[ ! -f "$ini_file" ]]; then
        sudo mkdir -p "$ini_dir"
        echo "extension=${ext}.so" | sudo tee "$ini_file" >/dev/null
    fi
    sudo phpenmod -v "$ver" "$ext" >/dev/null 2>&1 || true
    ok "PHP $ver: $ext enabled"
}

for line in "${PECL_LINES[@]}"; do
    IFS=':' read -r ext _ _ <<< "$line"
    for ver in $PHP_VERSIONS; do
        pecl_install_for_version "$ver" "$ext"
    done
done

# ─── Composer (bound to PHP default) ─────────────────────────────────
if ! command -v composer >/dev/null 2>&1; then
    info "installing Composer (with checksum verification)"
    expected_checksum="$(curl -fsSL https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');"
    actual_checksum="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"
    if [[ "$expected_checksum" != "$actual_checksum" ]]; then
        fail "Composer installer checksum mismatch"
        rm -f /tmp/composer-setup.php
        exit 1
    fi
    sudo php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f /tmp/composer-setup.php
else
    ok "Composer already installed ($(composer --version --no-ansi 2>/dev/null | head -1 || true))"
fi

# ─── Per-version composer wrappers ──────────────────────────────────
# `composer` (no suffix) always uses $PHP_DEFAULT (via update-alternatives
# → `php`). Generate `composer<maj.min>` for each NON-default version so
# `composer8.4 install` works from an 8.5-default environment without
# calling `php-use 8.4` globally.
#
# WSL installs php binaries at /usr/bin/php<maj.min>; composer lives at
# /usr/local/bin/composer. Wrappers land in ~/.local/bin (user-writable,
# in PATH by dotfiles/dev-bootstrap convention).
_compose_wrapper_dir="$HOME/.local/bin"
mkdir -p "$_compose_wrapper_dir"
for ver in $PHP_VERSIONS; do
    [[ "$ver" == "$PHP_DEFAULT" ]] && continue
    _php_bin="/usr/bin/php${ver}"
    _wrapper="$_compose_wrapper_dir/composer${ver}"
    if [[ ! -x "$_php_bin" ]]; then
        warn "composer${ver}: php${ver} not installed at $_php_bin — skipping wrapper"
        continue
    fi
    # Resolve composer at wrapper RUN time via an explicit priority list.
    # Same reasoning as the Mac side (see install.mac.sh for full rationale):
    # user-local > /usr/local > PATH-fallback. On WSL the common install
    # path is /usr/local/bin/composer (written by the installer above), but
    # a user may have overriden with ~/.local/bin/composer for specific
    # version control — honor that.
    cat > "$_wrapper" <<EOF
#!/usr/bin/env bash
# composer${ver} — Managed by dev-bootstrap / 10-languages.
# Runs Composer with PHP ${ver} instead of the machine's default PHP.
# Generated once per non-default version in PHP_VERSIONS; safe to delete
# (bootstrap re-creates) but not safe to edit (overwritten on next run).
set -e
_composer_bin=""
for c in "\$HOME/.local/bin/composer" "/usr/local/bin/composer"; do
    if [[ -x "\$c" ]]; then _composer_bin="\$c"; break; fi
done
if [[ -z "\$_composer_bin" ]]; then
    _self_dir="\$(cd "\$(dirname "\$0")" && pwd)"
    _composer_bin="\$(PATH="\${PATH//\$_self_dir:/}\${PATH//:\$_self_dir/}" command -v composer 2>/dev/null || true)"
fi
if [[ -z "\$_composer_bin" ]]; then
    echo "composer${ver}: no composer binary found (checked ~/.local/bin, /usr/local/bin, PATH)" >&2
    exit 127
fi
exec "${_php_bin}" "\$_composer_bin" "\$@"
EOF
    chmod +x "$_wrapper"
    ok "composer${ver} → php${ver}"
done
unset _compose_wrapper_dir _php_bin _wrapper

# ─── Python ────────────────────────────────────────────────────────────
if ! command -v python3 >/dev/null 2>&1; then
    info "installing python3"
    sudo apt-get install -y -qq python3 python3-pip python3-venv
else
    ok "python3 already installed ($(python3 --version))"
fi

ok "10-languages done — PHP default: $PHP_DEFAULT"
