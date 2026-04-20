#!/usr/bin/env bash
# 60-laravel-stack (mac): MySQL 8, Redis, Nginx, mkcert.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

: "${BREW_BIN:?BREW_BIN not set}"
: "${BREW_PREFIX:?BREW_PREFIX not set}"

# NGINX_CONF_DIR is consumed by DEPLOY
export NGINX_CONF_DIR="$BREW_PREFIX/etc/nginx/servers"

# ---------- MySQL 8 ----------
# brew's `mysql` formula tracks the latest major (9.x). Laravel work typically
# targets MySQL 8, so we pin to `mysql@8.0` explicitly. That formula is
# keg-only; we force-link after install so `mysql`/`mysqladmin`/`mysqldump`
# end up on $PATH via $BREW_PREFIX/bin.
#
# Escape hatch: Oracle's DMG installer (dev.mysql.com/downloads) installs to
# /usr/local/mysql. If detected, skip brew entirely — no sense installing MySQL
# twice, and brew can't manage the Oracle install anyway.
ORACLE_MYSQL_BIN="/usr/local/mysql/bin/mysql"
if [[ -x "$ORACLE_MYSQL_BIN" ]]; then
    info "Oracle MySQL detected at /usr/local/mysql — skipping brew install"
    command -v mysql >/dev/null 2>&1 || \
        warn "/usr/local/mysql/bin not on PATH; add it to your shell rc if needed"
else
    if "$BREW_BIN" list --formula mysql@8.0 >/dev/null 2>&1; then
        ok "mysql@8.0 already installed"
    else
        info "brew install mysql@8.0"
        "$BREW_BIN" install mysql@8.0
    fi
    "$BREW_BIN" link --force --overwrite mysql@8.0 >/dev/null 2>&1 || \
        warn "brew link mysql@8.0 failed — mysql may not be on PATH"
    info "starting mysql@8.0 via brew services"
    "$BREW_BIN" services start mysql@8.0 >/dev/null 2>&1 || true
fi

# ---------- Redis / Nginx / mkcert ----------
for p in redis nginx mkcert; do
    if "$BREW_BIN" list --formula "$p" >/dev/null 2>&1; then
        ok "$p already installed"
    else
        info "brew install $p"
        "$BREW_BIN" install "$p"
    fi
done

# Trust local CA
mkcert -install || warn "mkcert CA install may need re-run"

# Background services (mysql handled above)
info "starting redis, nginx via brew services"
"$BREW_BIN" services start redis  >/dev/null 2>&1 || true
"$BREW_BIN" services start nginx  >/dev/null 2>&1 || true

: "${CODE_DIR:=$HOME/code/web}"
mkdir -p "$CODE_DIR"
mkdir -p "$NGINX_CONF_DIR"
ok "CODE_DIR=$CODE_DIR"

export NGINX_CONF_DIR CODE_DIR

ok "60-laravel-stack (mac) done"
