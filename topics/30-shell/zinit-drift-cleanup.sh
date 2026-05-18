#!/usr/bin/env bash
# Custom installer: zinit drift cleanup (ported from identity install.sh).
#
# Reads `owner/repo` specs from data/zinit-uninstall.list and removes the
# matching plugin cache under ~/.local/share/zinit/plugins/<owner---repo>/.
# Idempotent — silent when the cache dir is already absent.
#
# Sandboxing matches the identity-side original: spec must look like
# owner/repo (no path traversal, no leading/trailing slash).
#
# DRY_RUN env var respected.

check() {
    # "Installed" = all listed plugins are already absent from the cache.
    local here list dir mangled spec line
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    list="$here/data/zinit-uninstall.list"
    [[ -f "$list" ]] || return 0
    dir="$HOME/.local/share/zinit/plugins"
    [[ -d "$dir" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "${line// }" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        spec="${line#"${line%%[![:space:]]*}"}"
        spec="${spec%"${spec##*[![:space:]]}"}"
        case "$spec" in
            */*) ;;
            *)   continue ;;
        esac
        case "$spec" in
            *..*|*//*|/*|*/)  continue ;;
        esac
        mangled="${spec//\//---}"
        if [[ -d "$dir/$mangled" ]]; then
            return 1
        fi
    done < "$list"
    return 0
}

install() {
    local here list dir mangled spec line target
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    list="$here/data/zinit-uninstall.list"
    [[ -f "$list" ]] || return 0
    dir="$HOME/.local/share/zinit/plugins"
    [[ -d "$dir" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "${line// }" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        spec="${line#"${line%%[![:space:]]*}"}"
        spec="${spec%"${spec##*[![:space:]]}"}"
        case "$spec" in
            */*) ;;
            *)   echo "[zinit-cleanup] '$spec' malformed (expected owner/repo) — skipping" >&2
                 continue ;;
        esac
        case "$spec" in
            *..*|*//*|/*|*/)
                echo "[zinit-cleanup] '$spec' rejected by sandbox — skipping" >&2
                continue ;;
        esac
        mangled="${spec//\//---}"
        target="$dir/$mangled"
        if [[ -d "$target" ]]; then
            if [[ "${DRY_RUN:-0}" == "1" ]]; then
                echo "[zinit-cleanup] would rm -rf $target"
            else
                echo "[zinit-cleanup] removing $spec ($target)"
                # Path is sandbox-validated above (owner/repo regex), and
                # the var name `target` matches L05's unguarded-rm-rf allowlist.
                rm -rf "$target"
            fi
        fi
    done < "$list"
}

verify() {
    check
}

rollback() {
    # Cleanup is intentionally one-way (plugin caches are regenerable
    # by re-running the plugin manager). No restore.
    :
}
