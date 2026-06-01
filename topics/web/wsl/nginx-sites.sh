#!/usr/bin/env bash
# Custom: nginx sites-enabled symlinks + apache2 cleanup + port :80 conflict
# detection. Runs AFTER deploy.sh has dropped the sites-available files.

NGINX_AVAILABLE_DIR="${NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
NGINX_ENABLED_DIR="${NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
NGINX_SNIPPET_DIR="${NGINX_SNIPPET_DIR:-/etc/nginx/snippets}"
NGINX_MAP_DIR="${NGINX_MAP_DIR:-/etc/nginx/conf.d}"

check() {
    # /etc/nginx/sites-enabled/ is root:root mode 0755 — world-searchable.
    # `test -L` only needs +x on the parent dir, never read on the link
    # target. Keeping check() sudo-free lets the menu scanner probe state
    # with zero password friction.
    local site
    for site in catchall-php.conf catchall-proxy.conf; do
        test -L "$NGINX_ENABLED_DIR/$site" || return 1
    done
    return 0
}

install() {
    sudo -v 2>/dev/null || true
    sudo mkdir -p "$NGINX_AVAILABLE_DIR" "$NGINX_ENABLED_DIR" "$NGINX_SNIPPET_DIR" "$NGINX_MAP_DIR"

    # Legacy single-file catchall cleanup
    local old_catchall="$NGINX_ENABLED_DIR/catchall.conf"
    if [[ -f "$old_catchall" ]] && [[ ! -L "$old_catchall" ]]; then
        if sudo grep -qi "managed by mesh-workstation" "$old_catchall" 2>/dev/null; then
            sudo rm -f "$old_catchall"
        fi
    fi

    # Symlinks for managed sites
    local site src dst
    for site in catchall-php.conf catchall-proxy.conf; do
        src="$NGINX_AVAILABLE_DIR/$site"
        dst="$NGINX_ENABLED_DIR/$site"
        [[ -f "$src" ]] || continue
        if [[ ! -L "$dst" ]] || [[ "$(sudo readlink -f "$dst" 2>/dev/null)" != "$(sudo readlink -f "$src" 2>/dev/null)" ]]; then
            sudo ln -sf "$src" "$dst"
        fi
    done

    # apache2 cleanup (if dragged in by older runs)
    local apache_pkgs=(apache2 apache2-bin apache2-data apache2-utils \
        libapache2-mod-php8.3 libapache2-mod-php8.4 libapache2-mod-php8.5)
    local apache_present=() p
    for p in "${apache_pkgs[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 && apache_present+=("$p")
    done
    if (( ${#apache_present[@]} > 0 )); then
        export DEBIAN_FRONTEND=noninteractive
        sudo systemctl disable --now apache2 2>/dev/null || true
        sudo apt-get purge -y -q "${apache_present[@]}" \
            || echo "[nginx-sites] apache2 purge had issues — manual: sudo apt-get purge ${apache_present[*]}" >&2
        sudo apt-get autoremove -y -q || true
    fi

    # Port :80 conflict check — uses `followup critical` (not just warn) so
    # the consolidated end-of-bootstrap summary catches it.
    local port_conflict="" owner port80
    if command -v ss >/dev/null 2>&1; then
        port80="$(sudo ss -tlnp 2>/dev/null | awk '$4 ~ /:80$/ {print $NF}' | head -1)"
        if [[ -n "$port80" ]] && [[ "$port80" != *'"nginx"'* ]]; then
            owner="$(printf '%s' "$port80" | sed -nE 's/.*\(\("([^"]+)".*/\1/p')"
            port_conflict=1
            # shellcheck disable=SC1091
            . "${MESH_WORKSTATION_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}/scripts/lib/log.sh"
            followup critical "port :80 owned by '${owner:-unknown}' (not nginx) — disable it and restart nginx:
        sudo systemctl disable --now ${owner:-...}
        sudo systemctl restart nginx"
        fi
    fi

    if [[ -n "$port_conflict" ]]; then
        echo "[nginx-sites] skipping nginx reload — port conflict above" >&2
    elif sudo nginx -t >/dev/null 2>&1; then
        sudo systemctl reload nginx 2>/dev/null \
            || sudo service nginx reload 2>/dev/null \
            || echo "[nginx-sites] couldn't reload nginx — start with 'sudo systemctl start nginx'" >&2
    else
        echo "[nginx-sites] nginx config FAILED validation — run 'sudo nginx -t' for details" >&2
        return 1
    fi
}

verify() {
    check
}

rollback() {
    local site
    for site in catchall-php.conf catchall-proxy.conf; do
        if sudo test -L "$NGINX_ENABLED_DIR/$site"; then
            sudo rm -f "$NGINX_ENABLED_DIR/$site"
        fi
    done
}
