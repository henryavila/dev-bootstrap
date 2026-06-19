# shellcheck shell=bash
# Service descriptor: php-fpm — PHP-FPM, one logical service per installed PHP
# version (languages topic). DYNAMIC: svcdef_php_fpm_enumerate expands it into
# php-fpm@<ver> rows so `mesh services list` shows one entry per version (T-005).
#   wsl → systemd units php<ver>-fpm, discovered from /etc/php/*/fpm.
#   mac → brew formulae php@<ver>, discovered from `brew list --formula`.
# Opt-out at boot on WSL by default (T-006).
svcdef_php_fpm_meta()   { echo "PHP-FPM|php,fpm|languages"; }

# Static fallback mapping: kind|scope is shared by every enumerated instance; the
# single-row target is emitted only when NO version is installed (empty enumerate).
svcdef_php_fpm_wsl()    { echo "systemd|system|php-fpm"; }
svcdef_php_fpm_mac()    { echo "brew||php"; }
svcdef_php_fpm_optout() { echo "wsl"; }

# svcdef_php_fpm_enumerate <os> — emit `id|display|target` per installed PHP
# version; the aggregator merges aliases/owner + kind/scope from the mapping
# above. Empty output ⇒ the aggregator emits the static single row.
#   wsl/linux: glob ${MESH_PHP_FPM_DIR:-/etc/php}/<ver>/fpm  → systemd unit php<ver>-fpm
#   mac:       brew list --formula | grep '^php@<ver>'        → formula php@<ver>
#              (the exact pattern topics/languages/templates/bin/php-use uses)
svcdef_php_fpm_enumerate() {
    local os="$1" dir ver formula
    case "$os" in
        wsl|linux)
            local root="${MESH_PHP_FPM_DIR:-/etc/php}"
            for dir in "$root"/*/fpm; do
                [[ -d "$dir" ]] || continue
                ver="$(basename "$(dirname "$dir")")"
                printf 'php-fpm@%s|PHP-FPM %s|php%s-fpm\n' "$ver" "$ver" "$ver"
            done
            ;;
        mac)
            while IFS= read -r formula; do
                [[ -n "$formula" ]] || continue
                ver="${formula#php@}"
                printf 'php-fpm@%s|PHP-FPM %s|%s\n' "$ver" "$ver" "$formula"
            done < <(brew list --formula 2>/dev/null | grep -oE '^php@[0-9]+\.[0-9]+$' | sort -V)
            ;;
    esac
}
