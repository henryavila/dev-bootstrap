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
    local here pecl_exts_file
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    pecl_exts_file="${here}/../data/php-extensions-pecl.txt"

    _mesh_owns_pecl_ext() {
        local wanted="$1" line ext
        [[ -f "$pecl_exts_file" ]] || return 1
        while IFS= read -r line; do
            case "$line" in
                ""|\#*) continue ;;
            esac
            IFS=':' read -r ext _ _ <<< "$line"
            [[ "$ext" == "$wanted" ]] && return 0
        done < "$pecl_exts_file"
        return 1
    }

    _candidate_ext_dirs_for_version() {
        local ver="$1" php_config pecl_cellar_dir api cellar_root dir
        php_config="${BREW_PREFIX}/opt/php@${ver}/bin/php-config"
        if [[ -x "$php_config" ]]; then
            pecl_cellar_dir="$("$php_config" --extension-dir 2>/dev/null || true)"
            if [[ -n "$pecl_cellar_dir" ]]; then
                printf '%s\n' "$pecl_cellar_dir"
                if [[ "$pecl_cellar_dir" == */pecl/* ]]; then
                    api="$(basename "$pecl_cellar_dir")"
                    cellar_root="$(dirname "$(dirname "$pecl_cellar_dir")")"
                    printf '%s\n' "${BREW_PREFIX}/lib/php/pecl/${api}"
                    printf '%s\n' "${cellar_root}/lib/php/${api}"
                fi
            fi
        fi
        for dir in "${BREW_PREFIX}"/lib/php/pecl/* \
            "${BREW_PREFIX}"/Cellar/php@"${ver}"/*/pecl/* \
            "${BREW_PREFIX}"/Cellar/php@"${ver}"/*/lib/php/*; do
            [[ -d "$dir" ]] && printf '%s\n' "$dir"
        done
    }

    _pecl_so_exists_for_version() {
        local ver="$1" ext="$2" dir
        while IFS= read -r dir; do
            [[ -n "$dir" && -f "${dir}/${ext}.so" ]] && return 0
        done < <(_candidate_ext_dirs_for_version "$ver" | awk '!seen[$0]++')
        return 1
    }

    _quarantine_ini() {
        local ini="$1" rel dest
        rel="${ini#"${BREW_PREFIX}/"}"
        [[ "$rel" == "$ini" ]] && rel="$(basename "$ini")"
        rel="${rel//\//__}"
        dest="${quarantine_root}/${rel}"
        mkdir -p "$quarantine_root"
        mv "$ini" "$dest" \
            && { moved=1; echo "[orphan-ini] moved $ini → $dest" >&2; }
    }

    local php_ver_dir php_etc_path
    for php_ver_dir in "${BREW_PREFIX}/etc/php"/*/; do
        [[ -d "$php_ver_dir" ]] || continue
        php_etc_path="${php_ver_dir%/}/conf.d"
        [[ -d "$php_etc_path" ]] || continue
        local php_ver
        php_ver="$(basename "${php_ver_dir%/}")"

        # Quarantine mesh-owned ext-*.ini entries when they name a PECL module
        # whose .so is absent from every valid extension directory for this PHP.
        local ext_ini ext_value ext_name
        for ext_ini in "$php_etc_path"/ext-*.ini; do
            [[ -f "$ext_ini" ]] || continue
            ext_value="$(awk -F= '/^[[:space:]]*extension[[:space:]]*=/{print $2; exit}' "$ext_ini" | tr -d ' "')"
            [[ -n "$ext_value" ]] || continue
            ext_name="$(basename "$ext_value" .so)"
            [[ "$ext_value" == *.so ]] || continue
            _mesh_owns_pecl_ext "$ext_name" || continue
            if ! _pecl_so_exists_for_version "$php_ver" "$ext_name"; then
                warn "php@${php_ver}: quarantining stale ini → $ext_ini (${ext_name}.so not found in candidate extension dirs)"
                _quarantine_ini "$ext_ini"
            fi
        done

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
                _quarantine_ini "$ini"
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
# This idempotent sweep creates no persistent runtime artifact. Its marker may
# therefore be removed honestly during a full stack uninstall.
uninstall() { :; }
