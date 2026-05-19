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
    local php_ver_dir php_etc_path
    for php_ver_dir in "${BREW_PREFIX}/etc/php"/*/; do
        [[ -d "$php_ver_dir" ]] || continue
        php_etc_path="${php_ver_dir%/}/conf.d"
        [[ -d "$php_etc_path" ]] || continue
        # Move any 99-*.ini lines pointing at a nonexistent .so into
        # /tmp/orphan-ini-cleanup-$$ for inspection.
        local cleanup_dir
        cleanup_dir="$(mktemp -d -t orphan-ini-cleanup.XXXXXX)"
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
                mv "$ini" "$cleanup_dir/" \
                    && echo "[orphan-ini] moved $ini → $cleanup_dir/" >&2
            fi
        done
        # Remove cleanup dir if empty
        rmdir "$cleanup_dir" 2>/dev/null || true
    done
}

verify() { return 0; }
rollback() { :; }
