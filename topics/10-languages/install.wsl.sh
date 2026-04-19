#!/usr/bin/env bash
# 10-languages (WSL): Node via fnm, PHP 8.4 via ondrej PPA, Python (apt), Composer.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

# ---------- fnm ----------
if ! command -v fnm >/dev/null 2>&1 && [[ ! -x "$HOME/.local/share/fnm/fnm" ]]; then
    info "installing fnm"
    curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
else
    ok "fnm already installed"
fi

# Source fnm in the current shell so we can run 'fnm install'
if [[ -x "$HOME/.local/share/fnm/fnm" ]]; then
    export PATH="$HOME/.local/share/fnm:$PATH"
fi
if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env)"
    # fnm list prints entries like "* v20.11.1" — detect any installed version
    if fnm list 2>/dev/null | grep -qE '\bv[0-9]+\.[0-9]+\.[0-9]+'; then
        ok "Node already installed via fnm ($(fnm current 2>/dev/null || echo '?'))"
    else
        info "installing Node LTS via fnm"
        fnm install --lts
        latest="$(fnm list | awk '/^\s*v[0-9]/ {print $NF}' | tail -1)"
        [[ -n "$latest" ]] && fnm default "$latest" || true
    fi
fi

# ---------- PHP 8.4 + Composer ----------
if ! command -v php >/dev/null 2>&1 || ! php -v 2>/dev/null | grep -q 'PHP 8.4'; then
    info "enabling ondrej/php PPA"
    if ! grep -Rq 'ondrej/php' /etc/apt/sources.list.d/ 2>/dev/null; then
        sudo add-apt-repository -y ppa:ondrej/php
        sudo apt-get update -qq
    fi
    info "installing PHP 8.4 + common extensions"
    sudo apt-get install -y -qq \
        php8.4 php8.4-cli php8.4-common \
        php8.4-mbstring php8.4-xml php8.4-curl \
        php8.4-zip php8.4-mysql php8.4-sqlite3 \
        php8.4-bcmath php8.4-gd php8.4-intl
else
    ok "PHP 8.4 already installed"
fi

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
    ok "Composer already installed"
fi

# ---------- Python ----------
if ! command -v python3 >/dev/null 2>&1; then
    info "installing python3"
    sudo apt-get install -y -qq python3 python3-pip python3-venv
else
    ok "python3 already installed ($(python3 --version))"
fi

ok "10-languages done"
