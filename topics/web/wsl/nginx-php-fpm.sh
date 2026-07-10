#!/usr/bin/env bash
# Custom: WSL runtime convergence for nginx + every declared php-fpm version.
#
# Package/config owners run earlier in the bundle. This final owner is the
# causal boundary: languages/php must verify clean before service activation,
# activation return codes remain visible, and runtime health must pass before
# the engine records convergence. It intentionally never changes boot-enable
# policy; services.default remains the sole owner of that bit.

_wsl_web_versions() {
    local versions="${PHP_VERSIONS:-${PHP_DEFAULT:-}}" conf ver
    if [[ -z "$versions" ]]; then
        conf="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../languages" 2>/dev/null && pwd)/data/php-versions.conf"
        [[ -f "$conf" ]] && versions="$(grep -vE '^\s*(#|$)' "$conf" | xargs)"
    fi
    if [[ -z "$versions" ]]; then
        echo "[web/nginx-php-fpm] no declared PHP versions; set PHP_VERSIONS or PHP_DEFAULT" >&2
        return 1
    fi
    for ver in $versions; do
        if [[ ! "$ver" =~ ^[0-9]+\.[0-9]+$ ]]; then
            echo "[web/nginx-php-fpm] invalid declared PHP version: $ver" >&2
            return 1
        fi
        printf '%s\n' "$ver"
    done
}

_wsl_web_php_owner_script() {
    if [[ -n "${MESH_PHP_OWNER_SCRIPT:-}" ]]; then
        printf '%s\n' "$MESH_PHP_OWNER_SCRIPT"
    else
        printf '%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../languages/wsl" && pwd)/php-stack.sh"
    fi
}

_wsl_web_default_version_valid() {
    local versions default ver
    versions="$(_wsl_web_versions)" || return 1
    default="${PHP_DEFAULT:-}"
    if [[ -z "$default" ]]; then
        echo "[web/nginx-php-fpm] PHP_DEFAULT is empty; declare the FPM version used by nginx" >&2
        return 1
    fi
    for ver in $versions; do
        [[ "$ver" == "$default" ]] && return 0
    done
    echo "[web/nginx-php-fpm] PHP_DEFAULT=$default is not present in PHP_VERSIONS=($versions)" >&2
    return 1
}

_wsl_web_php_owner_clean() {
    local owner tmp rc=0
    owner="$(_wsl_web_php_owner_script)"
    if [[ ! -r "$owner" ]]; then
        echo "[web/nginx-php-fpm] languages/php verifier is unreadable: $owner" >&2
        return 1
    fi
    tmp="$(mktemp -d -t mesh-wsl-web-php.XXXXXX)" || return 1
    bash -c '. "$1"; verify' _ "$owner" >"$tmp/out" 2>"$tmp/err" || rc=$?
    if [[ "$rc" -ne 0 || -s "$tmp/err" ]]; then
        echo "[web/nginx-php-fpm] languages/php verify failed before service activation (rc=$rc); repair languages/php first" >&2
        if [[ -s "$tmp/err" ]]; then
            sed -n '1,4p' "$tmp/err" >&2
        else
            sed -n '1,4p' "$tmp/out" >&2
        fi
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"
    return 0
}

_wsl_web_fpm_bin() {
    local ver="$1" bin
    bin="${PHP_FPM_BIN_DIR:-/usr/sbin}/php-fpm${ver}"
    if [[ -x "$bin" ]]; then
        printf '%s\n' "$bin"
        return 0
    fi
    command -v "php-fpm${ver}" 2>/dev/null || return 1
}

_wsl_web_fpm_probes_clean() {
    local versions ver fpm stderr rc
    versions="$(_wsl_web_versions)" || return 1
    for ver in $versions; do
        fpm="$(_wsl_web_fpm_bin "$ver")" || {
            echo "[web/nginx-php-fpm] php-fpm${ver} health failed before service activation: executable missing" >&2
            return 1
        }
        stderr=""
        rc=0
        stderr="$("$fpm" --version 2>&1 >/dev/null)" || rc=$?
        if [[ "$rc" -ne 0 || -n "$stderr" ]]; then
            echo "[web/nginx-php-fpm] php-fpm${ver} health failed before service activation (rc=$rc); repair languages/php first" >&2
            [[ -n "$stderr" ]] && printf '%s\n' "$stderr" | sed -n '1,4p' >&2
            return 1
        fi
    done
    return 0
}

_wsl_web_systemctl_bin() {
    local bin="${MESH_SYSTEMCTL_BIN:-systemctl}"
    command -v "$bin" 2>/dev/null || {
        echo "[web/nginx-php-fpm] systemd is required for WSL service convergence" >&2
        return 1
    }
}

_wsl_web_nginx_bin() {
    local bin="${MESH_NGINX_BIN:-nginx}"
    if command -v "$bin" >/dev/null 2>&1; then
        command -v "$bin"
    elif [[ -x /usr/sbin/nginx ]]; then
        printf '%s\n' /usr/sbin/nginx
    else
        return 1
    fi
}

_wsl_web_nginx_config_clean() {
    local nginx output rc=0
    nginx="$(_wsl_web_nginx_bin)" || {
        echo "[web/nginx-php-fpm] nginx executable is missing" >&2
        return 1
    }
    output="$(sudo "$nginx" -t 2>&1)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        [[ -n "$output" ]] && printf '%s\n' "$output" | sed -n '1,6p' >&2
        echo "[web/nginx-php-fpm] nginx configuration validation failed (rc=$rc); run \`sudo nginx -t\`" >&2
        return "$rc"
    fi
    return 0
}

_wsl_web_activate_unit() {
    local unit="$1" systemctl_bin output rc=0
    systemctl_bin="$(_wsl_web_systemctl_bin)" || return 1
    output="$(sudo "$systemctl_bin" restart "$unit" 2>&1)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        [[ -n "$output" ]] && printf '%s\n' "$output" | sed -n '1,6p' >&2
        echo "[web/nginx-php-fpm] activation failed for $unit (rc=$rc) after PHP passed; run \`mesh doctor --fix\` and inspect \`systemctl status $unit\`" >&2
        return "$rc"
    fi
    return 0
}

_wsl_web_unit_active() {
    local unit="$1" systemctl_bin
    systemctl_bin="$(_wsl_web_systemctl_bin)" || return 1
    "$systemctl_bin" is-active --quiet "$unit" >/dev/null 2>&1
}

_wsl_web_nginx_serving() {
    local host="${MESH_NGINX_HEALTH_HOST:-127.0.0.1}"
    local port="${MESH_NGINX_HEALTH_PORT:-80}"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || return 1
    (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null
}

_wsl_web_stack_ok() {
    local versions ver socket
    WSL_WEB_STACK_FAILURE=""
    versions="$(_wsl_web_versions)" || {
        WSL_WEB_STACK_FAILURE="PHP version resolution"
        return 1
    }
    for ver in $versions; do
        if ! _wsl_web_unit_active "php${ver}-fpm"; then
            WSL_WEB_STACK_FAILURE="php${ver}-fpm"
            return 1
        fi
        socket="${PHP_FPM_RUN_DIR:-/run/php}/php${ver}-fpm.sock"
        if [[ ! -S "$socket" ]]; then
            WSL_WEB_STACK_FAILURE="php${ver}-fpm socket ($socket)"
            return 1
        fi
    done
    if ! _wsl_web_unit_active nginx; then
        WSL_WEB_STACK_FAILURE="nginx"
        return 1
    fi
    if ! _wsl_web_nginx_serving; then
        WSL_WEB_STACK_FAILURE="nginx listener (${MESH_NGINX_HEALTH_HOST:-127.0.0.1}:${MESH_NGINX_HEALTH_PORT:-80})"
        return 1
    fi
    return 0
}

_wsl_web_wait_for_stack() {
    local attempts="${WSL_WEB_VERIFY_ATTEMPTS:-5}" n
    [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || attempts=5
    for ((n=1; n<=attempts; n++)); do
        _wsl_web_stack_ok && return 0
        (( n < attempts )) && sleep 1
    done
    return 1
}

_wsl_web_report_stack_failure() {
    local component="${WSL_WEB_STACK_FAILURE:-unknown}"
    echo "[web/nginx-php-fpm] service post-condition failed after activation: $component is not healthy. Run \`mesh doctor --fix\` and inspect \`systemctl status\`" >&2
}

check() {
    WSL_WEB_STACK_FAILURE=""
    _wsl_web_default_version_valid || return 1
    _wsl_web_php_owner_clean || return 1
    _wsl_web_fpm_probes_clean || return 1
    _wsl_web_stack_ok
}

install() {
    local versions ver
    WSL_WEB_STACK_FAILURE=""
    _wsl_web_default_version_valid || return 1
    _wsl_web_php_owner_clean || return 1
    _wsl_web_fpm_probes_clean || return 1
    sudo -v 2>/dev/null || true
    _wsl_web_nginx_config_clean || return $?

    versions="$(_wsl_web_versions)" || return 1
    for ver in $versions; do
        _wsl_web_activate_unit "php${ver}-fpm" || return $?
    done
    _wsl_web_activate_unit nginx || return $?

    if ! _wsl_web_wait_for_stack; then
        _wsl_web_report_stack_failure
        return 1
    fi
    # Re-probe after activation so a successful restart cannot mask runtime PHP
    # drift that appeared while php-fpm/nginx loaded their full configuration.
    _wsl_web_php_owner_clean || return 1
    _wsl_web_fpm_probes_clean || return 1
    return 0
}

verify() {
    if ! check; then
        if [[ -n "${WSL_WEB_STACK_FAILURE:-}" ]]; then
            _wsl_web_report_stack_failure
        fi
        return 1
    fi
    return 0
}

repair() { install; }
rollback() { :; }
