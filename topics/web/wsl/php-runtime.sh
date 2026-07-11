#!/usr/bin/env bash
# Shared WSL web boundary for the PHP runtime selected by languages/php.
# Explicit declarations always win. When the engine applies a dependent bundle
# in a fresh subshell without persisted params, derive from the versioned PHP
# binaries and the default `php` executable that languages/php just converged.

_mesh_web_php_version_from_bin() {
    local php_bin="$1" version=""
    [[ -x "$php_bin" ]] || return 1
    version="$("$php_bin" -r 'printf("%d.%d", PHP_MAJOR_VERSION, PHP_MINOR_VERSION);' 2>/dev/null)" || return 1
    [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s\n' "$version"
}

_mesh_web_php_runtime_versions() {
    local declared="${PHP_VERSIONS:-${PHP_DEFAULT:-}}" ver declared_count=0
    if [[ -n "$declared" ]]; then
        for ver in $declared; do
            declared_count=$((declared_count + 1))
            [[ "$ver" =~ ^[0-9]+\.[0-9]+$ ]] || {
                echo "[web/php-runtime] invalid declared PHP version: $ver" >&2
                return 1
            }
            printf '%s\n' "$ver"
        done
        if [[ "$declared_count" -eq 0 ]]; then
            echo "[web/php-runtime] declared PHP runtime list contains no versions" >&2
            return 1
        fi
        return 0
    fi

    local bin_dir="${PHP_CLI_BIN_DIR:-/usr/bin}" candidate base seen="" found=0
    for candidate in "$bin_dir"/php[0-9]*.[0-9]*; do
        [[ -x "$candidate" ]] || continue
        base="${candidate##*/}"
        ver="${base#php}"
        [[ "$ver" =~ ^[0-9]+\.[0-9]+$ ]] || continue
        case " $seen " in
            *" $ver "*) continue ;;
        esac
        seen="${seen:+$seen }$ver"
        printf '%s\n' "$ver"
        found=1
    done
    (( found == 1 )) && return 0

    local default_bin=""
    if [[ -x "$bin_dir/php" ]]; then
        default_bin="$bin_dir/php"
    else
        default_bin="$(command -v php 2>/dev/null || true)"
    fi
    ver="$(_mesh_web_php_version_from_bin "$default_bin")" || {
        echo "[web/php-runtime] no declared or executable PHP runtime found after languages/php" >&2
        return 1
    }
    printf '%s\n' "$ver"
}

_mesh_web_php_runtime_default() {
    local versions="$1" default="${PHP_DEFAULT:-}" ver count=0 only="" flat="" default_bin=""
    if [[ -z "$default" ]]; then
        local bin_dir="${PHP_CLI_BIN_DIR:-/usr/bin}"
        if [[ -x "$bin_dir/php" ]]; then
            default_bin="$bin_dir/php"
        else
            default_bin="$(command -v php 2>/dev/null || true)"
        fi
        default="$(_mesh_web_php_version_from_bin "$default_bin" 2>/dev/null || true)"
    fi

    for ver in $versions; do
        count=$((count + 1))
        only="$ver"
        flat="${flat:+$flat }$ver"
        [[ -n "$default" && "$ver" == "$default" ]] && {
            printf '%s\n' "$default"
            return 0
        }
    done
    if [[ -z "$default" && "$count" -eq 1 ]]; then
        printf '%s\n' "$only"
        return 0
    fi
    if [[ -n "$default" ]]; then
        echo "[web/php-runtime] PHP_DEFAULT=$default is not present in PHP_VERSIONS=($flat)" >&2
    else
        echo "[web/php-runtime] could not resolve the default PHP runtime from ($versions)" >&2
    fi
    return 1
}
