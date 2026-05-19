#!/usr/bin/env bash
# Custom: pre-migrate legacy unmarked nginx files (60-web-stack mac).
#
# deploy.sh refuses to overwrite files in $BREW_PREFIX/etc/nginx/ that
# don't carry the "managed by dev-bootstrap" marker — that's the safety
# rail protecting user-authored configs from silent overwrite. But on
# machines that ran an OLDER bootstrap (before the marker convention was
# added to these specific templates), the files exist on disk without
# the marker. They ARE ours, just from an earlier era.
#
# This block recognizes those exact paths and quarantines unmarked
# instances by renaming to <path>.pre-bootstrap-bak-<timestamp>. deploy.sh
# then writes the new version with the marker. Backup is preserved so the
# user can diff if curious; it is never auto-deleted.
#
# Limited to the 5 nginx files we deploy on Mac via Valet — nothing
# outside that allowlist is touched.

check() {
    # One-shot migration; always re-run (silent when nothing to migrate).
    return 1
}

install() {
    : "${BREW_PREFIX:?BREW_PREFIX not set — run through setup.sh}"

    local NGINX_SNIPPET_DIR="$BREW_PREFIX/etc/nginx/snippets"
    local NGINX_MAP_DIR="$BREW_PREFIX/etc/nginx/conf.d"
    local NGINX_AVAILABLE_DIR="$BREW_PREFIX/etc/nginx/sites-available"

    local LEGACY_FILES=(
        "$NGINX_SNIPPET_DIR/dev-bootstrap-security.conf"
        "$NGINX_SNIPPET_DIR/dev-bootstrap-proxy.conf"
        "$NGINX_MAP_DIR/dev-bootstrap-maps.conf"
        "$NGINX_AVAILABLE_DIR/catchall-php.conf"
        "$NGINX_AVAILABLE_DIR/catchall-proxy.conf"
    )

    local _migration_ts
    _migration_ts="$(date +%Y%m%d-%H%M%S)"
    local legacy backup
    for legacy in "${LEGACY_FILES[@]}"; do
        [[ -z "$legacy" ]] && continue
        if sudo test -f "$legacy" 2>/dev/null \
           && ! sudo grep -qi "managed by dev-bootstrap" "$legacy" 2>/dev/null; then
            backup="${legacy}.pre-bootstrap-bak-${_migration_ts}"
            sudo mv "$legacy" "$backup" \
                && echo "[migrate-legacy-nginx] $legacy → $backup"
        fi
    done
}

verify() {
    return 0
}

rollback() {
    :
}
