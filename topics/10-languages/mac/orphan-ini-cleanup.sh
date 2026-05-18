#!/usr/bin/env bash
# Custom: remove orphan PECL .ini files from the old wrong-path bug (mac).

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
            if [[ -n "$path" ]] && [[ ! -e "$path" ]]; then
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
