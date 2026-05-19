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
    local legacy backup mv_rc
    for legacy in "${LEGACY_FILES[@]}"; do
        [[ -z "$legacy" ]] && continue
        sudo test -f "$legacy" 2>/dev/null || continue
        # Skip files that already carry the new marker — those are ours
        # and don't need migration.
        sudo grep -qi "managed by dev-bootstrap" "$legacy" 2>/dev/null && continue
        # Codex review 2026-05-19 (C-F003 + F-F003): the previous logic
        # migrated ANY unmarked file at an allowlisted path. A user-authored
        # config at one of these paths would be silently moved out of
        # service. Now we require a "dev-bootstrap" signature SOMEWHERE in
        # the file content (older marker convention used the substring
        # before the canonical "Managed by dev-bootstrap" sentence). A
        # user-authored file is overwhelmingly unlikely to contain that
        # substring. Without the signature we leave the file in place and
        # emit an advisory so deploy.sh's overwrite-refusal surfaces the
        # conflict to the user.
        if ! sudo grep -qi "dev-bootstrap" "$legacy" 2>/dev/null; then
            echo "[migrate-legacy-nginx] $legacy: unmarked AND no dev-bootstrap signature — leaving in place. deploy.sh will refuse to overwrite; remove or rename manually if you want our template here." >&2
            continue
        fi
        backup="${legacy}.pre-bootstrap-bak-${_migration_ts}"
        # Codex review 2026-05-19 (F-F003): the previous `sudo mv "$legacy" "$backup" && echo ...`
        # swallowed mv failures whenever the echo evaluated 0, and verify
        # then returned 0 unconditionally — masking incomplete migrations.
        # Now we capture rc and return non-zero on any mv failure.
        if sudo mv "$legacy" "$backup"; then
            echo "[migrate-legacy-nginx] $legacy → $backup"
        else
            mv_rc=$?
            echo "[migrate-legacy-nginx] sudo mv failed (rc=$mv_rc): $legacy → $backup" >&2
            return "$mv_rc"
        fi
    done
}

verify() {
    : "${BREW_PREFIX:?BREW_PREFIX not set}"
    # Codex review 2026-05-19 (F-F003): the previous verify returned 0
    # unconditionally, so a failed install was indistinguishable from a
    # successful one. Now we assert that no allowlisted legacy file
    # remains in the unmarked+signed state install() would have migrated.
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
    local legacy
    for legacy in "${LEGACY_FILES[@]}"; do
        sudo test -f "$legacy" 2>/dev/null || continue
        sudo grep -qi "managed by dev-bootstrap" "$legacy" 2>/dev/null && continue
        # File present, no new marker. Verify passes ONLY if it lacks the
        # dev-bootstrap signature (= user-authored, intentionally left).
        sudo grep -qi "dev-bootstrap" "$legacy" 2>/dev/null && return 1
    done
    return 0
}

rollback() {
    :
}
