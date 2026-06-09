#!/usr/bin/env bash
# Custom: sweep orphan ini from old wrong path (PECL extension .ini files
# pointing at non-existent .so files on macOS, residue of pre-fix behavior
# that wrote inis to $BREW_PREFIX/opt/php@X.Y/etc/ instead of
# $BREW_PREFIX/etc/php/X.Y/conf.d/).

check() {
    # Treat as needs-run; the inner loop is silent when nothing matches.
    return 1
}

install() {
    : "${BREW_PREFIX:?BREW_PREFIX not set}"
    # Stable, mesh-managed quarantine dir under the state area. Created
    # lazily only when the first orphan is actually moved — so the
    # no-op path (the common case for this idempotent item) leaves
    # nothing behind, and the move path quarantines into a single
    # known location instead of a fresh per-run mktemp dir in /tmp
    # that would never be cleaned up.
    local quarantine_root
    quarantine_root="$(mesh_state_dir)/orphan-ini-quarantine"
    local moved=0
    local php_ver_dir php_etc_path
    for php_ver_dir in "${BREW_PREFIX}/etc/php"/*/; do
        [[ -d "$php_ver_dir" ]] || continue
        php_etc_path="${php_ver_dir%/}/conf.d"
        [[ -d "$php_etc_path" ]] || continue
        # Quarantine any 99-*.ini lines pointing at a nonexistent .so.
        local ini path
        for ini in "$php_etc_path"/99-*.ini; do
            [[ -f "$ini" ]] || continue
            path="$(awk -F= '/^extension/{print $2}' "$ini" | tr -d ' "')"
            # Codex review 2026-05-19 (E-F005): the previous test
            # `[[ -n "$path" ]] && [[ ! -e "$path" ]]` treated a bare
            # module name like `extension=imagick.so` (valid PHP syntax;
            # PHP resolves it against the active extension_dir) as a
            # filesystem path. That path obviously doesn't exist
            # relative to cwd, so the ini got moved out — disabling
            # working PECL extensions. Now we only treat ABSOLUTE .so
            # paths as orphan candidates. Bare module names are PHP's
            # responsibility to resolve and we leave them alone.
            if [[ "$path" == /*.so ]] && [[ ! -e "$path" ]]; then
                mkdir -p "$quarantine_root"
                mv "$ini" "$quarantine_root/" \
                    && { moved=1; echo "[orphan-ini] moved $ini → $quarantine_root/" >&2; }
            fi
        done
    done
    # Surface the quarantine location so the user knows where the moved
    # inis went (and can delete them once satisfied).
    if [[ "$moved" -eq 1 ]]; then
        followup info "orphan PECL .ini files were quarantined to $quarantine_root — review and remove once satisfied."
    fi
}

verify() { return 0; }
rollback() { :; }
