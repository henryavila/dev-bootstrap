#!/usr/bin/env bash
# Custom: nginx sites-enabled symlinks + apache2 cleanup + port :80 conflict
# detection. Runs AFTER deploy.sh has dropped the sites-available files.

NGINX_AVAILABLE_DIR="${NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
NGINX_ENABLED_DIR="${NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
NGINX_SNIPPET_DIR="${NGINX_SNIPPET_DIR:-/etc/nginx/snippets}"
NGINX_MAP_DIR="${NGINX_MAP_DIR:-/etc/nginx/conf.d}"

check() {
    # /etc/nginx/sites-enabled/ is root:root mode 0755 — world-searchable —
    # and the sites-available targets land at 0644 (world-readable, deploy's
    # default perms). So both `test -L` (needs only +x on the parent dir) and
    # the content grep (follows the link, reads the 0644 target) work without
    # sudo. Keeping check() sudo-free lets the menu scanner probe state with
    # zero password friction.
    #
    # Hardening (§D filesystem): bare `test -L` passed on a DANGLING symlink
    # (deploy removed/never wrote the sites-available target) and on a corrupt
    # or truncated config — a half-installed false-keep. We now require the
    # link to be a symlink, its target to RESOLVE (`-e` follows the link), and
    # the resolved config to still carry its mesh-managed sentinel comment
    # (template header line 1, a plain comment untouched by envsubst). grep on
    # a dangling/absent target also fails, covering the `-e` case transitively.
    local site
    for site in catchall-php.conf catchall-proxy.conf; do
        test -L "$NGINX_ENABLED_DIR/$site"  || return 1
        test -e "$NGINX_ENABLED_DIR/$site"  || return 1
        grep -qi "managed by mesh-workstation" "$NGINX_ENABLED_DIR/$site" 2>/dev/null || return 1
    done
    return 0
}

install() {
    sudo -n -v >/dev/null 2>&1 || true
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

repair() {
    # Engine --repair sweep: re-run install() to relink a dangling/corrupt
    # symlink. install() is idempotent (gated `ln -sf` on `[[ -f $src ]]`, the
    # serve-config deploy that writes $src runs earlier in the bundle), so this
    # auto-heals the §D filesystem break instead of reporting "no safe auto-repair".
    install
}

rollback() {
    local site
    for site in catchall-php.conf catchall-proxy.conf; do
        if sudo test -L "$NGINX_ENABLED_DIR/$site"; then
            sudo rm -f "$NGINX_ENABLED_DIR/$site"
        fi
    done
}
