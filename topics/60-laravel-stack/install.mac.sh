#!/usr/bin/env bash
# 60-laravel-stack (mac): MySQL, Redis, Nginx, mkcert.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

: "${BREW_BIN:?BREW_BIN not set}"
: "${BREW_PREFIX:?BREW_PREFIX not set}"

# NGINX_CONF_DIR is consumed by DEPLOY
export NGINX_CONF_DIR="$BREW_PREFIX/etc/nginx/servers"

for p in mysql redis nginx mkcert; do
    if "$BREW_BIN" list --formula "$p" >/dev/null 2>&1; then
        ok "$p already installed"
    else
        info "brew install $p"
        "$BREW_BIN" install "$p"
    fi
done

# Trust local CA
mkcert -install || warn "mkcert CA install may need re-run"

# Background services
info "starting mysql, redis, nginx via brew services"
"$BREW_BIN" services start mysql  >/dev/null 2>&1 || true
"$BREW_BIN" services start redis  >/dev/null 2>&1 || true
"$BREW_BIN" services start nginx  >/dev/null 2>&1 || true

: "${CODE_DIR:=$HOME/code/web}"
mkdir -p "$CODE_DIR"
mkdir -p "$NGINX_CONF_DIR"
ok "CODE_DIR=$CODE_DIR"

export NGINX_CONF_DIR CODE_DIR

ok "60-laravel-stack (mac) done"
