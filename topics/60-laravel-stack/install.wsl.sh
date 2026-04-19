#!/usr/bin/env bash
# 60-laravel-stack (WSL): MySQL, Redis, Nginx, PHP-FPM 8.4, mkcert.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

# Expose NGINX_CONF_DIR for deploy.sh (see DEPLOY file)
export NGINX_CONF_DIR="/etc/nginx/sites-enabled"

pkgs=(mysql-server redis-server nginx php8.4-fpm)
missing=()
for p in "${pkgs[@]}"; do
    if dpkg -s "$p" >/dev/null 2>&1; then
        ok "$p already installed"
    else
        missing+=("$p")
    fi
done

if [[ "${#missing[@]}" -gt 0 ]]; then
    info "installing: ${missing[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y -qq "${missing[@]}"
fi

# mkcert (not in default apt)
if ! command -v mkcert >/dev/null 2>&1; then
    info "installing mkcert"
    sudo apt-get install -y -qq libnss3-tools
    mkcert_ver="$(curl -fsSL https://api.github.com/repos/FiloSottile/mkcert/releases/latest | jq -r '.tag_name')"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/mkcert" "https://github.com/FiloSottile/mkcert/releases/download/${mkcert_ver}/mkcert-${mkcert_ver}-linux-amd64"
    sudo install -m 0755 "$tmp/mkcert" /usr/local/bin/mkcert
    rm -rf "$tmp"
    mkcert -install || warn "mkcert CA install may need re-run interactively"
else
    ok "mkcert already installed"
fi

# Ensure $CODE_DIR exists (used by link-project and nginx catchall)
: "${CODE_DIR:=$HOME/code/web}"
mkdir -p "$CODE_DIR"
ok "CODE_DIR=$CODE_DIR"

# Expose for deploy.sh
export NGINX_CONF_DIR CODE_DIR

ok "60-laravel-stack (wsl) done — reminder: 'sudo systemctl start mysql redis nginx php8.4-fpm' and 'link-project <name>' to wire new sites"
