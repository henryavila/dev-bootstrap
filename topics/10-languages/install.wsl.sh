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

# Read extension lists once
mapfile -t APT_EXTS < <(grep -vE '^\s*(#|$)' "$HERE/data/php-extensions-apt.txt")

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

declare -a PECL_LINES
mapfile -t PECL_LINES < <(grep -vE '^\s*(#|$)' "$HERE/data/php-extensions-pecl.txt")

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
    local pecl_bin="/usr/bin/pecl${ver}"
    # ondrej ships pecl8.X symlinks; fall back to generic `pecl` which picks
    # up whichever phpize is currently the default (we set it above).
    if [[ ! -x "$pecl_bin" ]]; then
        pecl_bin="$(command -v pecl || true)"
        [[ -z "$pecl_bin" ]] && { warn "pecl binary not found for $ver — skipping"; return; }
    fi

    # Already loaded?
    if php${ver} -m 2>/dev/null | grep -qiE "^${ext}\$|^${ext//pdo_/PDO_}\$"; then
        ok "PHP $ver: $ext already loaded"
        return 0
    fi

    info "PHP $ver: pecl install $ext"
    # `-f` forces rebuild when the same version is already cached. Piping `\n`
    # accepts all default prompts (imagick asks about ImageMagick autodetect).
    printf '\n' | sudo "$pecl_bin" install -f "$ext" >/dev/null 2>&1 || {
        warn "PHP $ver: pecl install $ext failed — continuing (check logs manually)"
        return 0
    }

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

# ─── Python ────────────────────────────────────────────────────────────
if ! command -v python3 >/dev/null 2>&1; then
    info "installing python3"
    sudo apt-get install -y -qq python3 python3-pip python3-venv
else
    ok "python3 already installed ($(python3 --version))"
fi

ok "10-languages done — PHP default: $PHP_DEFAULT"
