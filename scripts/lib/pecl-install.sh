#!/usr/bin/env bash
# shellcheck shell=bash
# lib/pecl-install.sh — canonical per-version PECL install for Linux/WSL.
# Source this file; do NOT execute. Exposes:
#
#   pecl_install_for_version_linux  VER  EXT  [CONTEXT_LABEL]
#
# Why a shared lib:
#   ondrej's `/usr/bin/pecl` is a single shell script bound to whatever
#   PHP `update-alternatives` points at. Building an extension for a
#   non-default PHP version requires four complementary env-var overrides
#   (PHP binary, bin_dir for PATH lookup, ext_dir for install target,
#   metadata_dir for registry isolation). This fix is non-trivial and
#   MUST be applied identically everywhere we install a PECL extension
#   — install.wsl.sh for the base extensions, install-mssql-driver.sh
#   for sqlsrv/pdo_sqlsrv, and any future topic that adds PECL extras.
#   Duplicating the implementation invites the next regression.
#
# The fix itself is documented in
#   dotfiles/.ai/memory/feedback_pecl_wsl_requires_pear_env_vars.md
# which covers every known failure mode discovered during the
# 2026-04-23 saga (5 successive commits to converge on a working
# implementation).

# Guard against double-source
if declare -F pecl_install_for_version_linux >/dev/null 2>&1; then
    return 0 2>/dev/null || true
fi

# pecl_install_for_version_linux — build + enable $ext for PHP $ver.
#
# Args:
#   $1  PHP version     e.g. "8.3"
#   $2  extension name  e.g. "igbinary" / "sqlsrv"
#   $3  (optional) failure-message suffix — appended to warn() on a
#       build failure so topic-specific context is preserved (e.g.
#       "SQL Server support won't work on this PHP"). Defaults to
#       empty string.
#
# Contract:
#   - Idempotent: returns 0 fast when `php${ver} -m` already lists $ext.
#   - Skips cleanly (returns 0) if required per-version binaries are
#     missing; the caller decides whether that's a critical failure.
#   - Never exits nonzero on install failure — emits a warn() + log
#     tail and returns 0, so a single failed extension doesn't abort
#     the PECL loop under `set -e`.
#
# Environment dependencies:
#   - `info`, `warn`, `ok`  (from lib/log.sh)
#   - sudo (bootstrap warms the ticket upfront; this function does not
#     re-warm it — a single missed extension is acceptable, a stalled
#     bootstrap is not)
pecl_install_for_version_linux() {
    local ver="$1" ext="$2" fail_suffix="${3:-}"

    # ondrej does NOT ship per-version pecl binaries — only /usr/bin/pecl
    # plus phpize${ver} and php-config${ver}. See the feedback memory
    # for the full analysis. Below we override the four relevant stages
    # (shell, PEAR Builder, installer, registry) to pin everything to
    # the target version.
    local pecl_bin="/usr/bin/pecl"
    local php_bin="/usr/bin/php${ver}"
    local phpize_bin="/usr/bin/phpize${ver}"
    local php_config_bin="/usr/bin/php-config${ver}"

    for _b in "$pecl_bin" "$php_bin" "$phpize_bin" "$php_config_bin"; do
        if [[ ! -x "$_b" ]]; then
            warn "PHP $ver: required binary $_b missing — skipping $ext"
            return 0
        fi
    done

    local api
    api="$("$php_config_bin" --phpapi 2>/dev/null)"
    if [[ -z "$api" ]]; then
        warn "PHP $ver: could not resolve PHP API from $php_config_bin — skipping $ext"
        return 0
    fi
    local target_ext_dir="/usr/lib/php/${api}"
    local so_path="${target_ext_dir}/${ext}.so"

    # Already loaded? Fast path — `pdo_sqlsrv` loads as `pdo_sqlsrv` but
    # appears in `php -m` as `PDO_SQLSRV`, so match both cases via the
    # `pdo_`→`PDO_` substitution.
    if php"${ver}" -m 2>/dev/null \
        | grep -qiE "^${ext}\$|^${ext//pdo_/PDO_}\$"; then
        ok "PHP $ver: $ext already loaded"
        return 0
    fi

    # Four scratch-state env vars + sudo env:
    #   PHP_PEAR_PHP_BIN        → /usr/bin/pecl's `exec` target
    #   PHP_PEAR_BIN_DIR        → dir PEAR prepends to PATH; our shim
    #                             has phpize/php-config → per-version
    #   PHP_PEAR_EXTENSION_DIR  → where .so lands
    #   PHP_PEAR_METADATA_DIR   → isolated registry per-call; without
    #                             this, the next -f install uninstalls
    #                             the previous version's .so first
    local tmpbin tmpmeta
    tmpbin="$(mktemp -d -t dev-bootstrap-pecl-bin.XXXXXX)"
    tmpmeta="$(mktemp -d -t dev-bootstrap-pecl-meta.XXXXXX)"
    ln -s "$phpize_bin"      "$tmpbin/phpize"
    ln -s "$php_config_bin"  "$tmpbin/php-config"
    ln -s "$php_bin"         "$tmpbin/php"
    # sudo rm + ||true: pecl runs as root and writes root-owned files
    # into $tmpmeta (.registry/*, .channels/*). Plain `rm` as user
    # fails → under `set -e` the trap aborts the topic loop.
    trap 'sudo rm -rf "$tmpbin" "$tmpmeta" 2>/dev/null || true' RETURN

    info "PHP $ver: pecl install $ext (target: $so_path)"
    local pecl_out="" pecl_rc=0
    pecl_out=$(printf '\n' | sudo env \
        PHP_PEAR_PHP_BIN="$php_bin" \
        PHP_PEAR_BIN_DIR="$tmpbin" \
        PHP_PEAR_METADATA_DIR="$tmpmeta" \
        PHP_PEAR_EXTENSION_DIR="$target_ext_dir" \
        "$pecl_bin" install -f "$ext" 2>&1) || pecl_rc=$?

    if [[ "$pecl_rc" -ne 0 ]] || [[ ! -f "$so_path" ]]; then
        local msg="PHP $ver: pecl install $ext failed (exit=$pecl_rc, .so not at $so_path)"
        [[ -n "$fail_suffix" ]] && msg="$msg — $fail_suffix"
        warn "$msg"
        if [[ -n "$pecl_out" ]]; then
            printf '%s\n' "$pecl_out" | tail -6 | sed 's/^/      /' >&2
        fi
        return 0
    fi

    local ini_dir="/etc/php/${ver}/mods-available"
    local ini_file="${ini_dir}/${ext}.ini"
    if [[ ! -f "$ini_file" ]]; then
        sudo mkdir -p "$ini_dir"
        echo "extension=${ext}.so" | sudo tee "$ini_file" >/dev/null
    fi
    sudo phpenmod -v "$ver" "$ext" >/dev/null 2>&1 || true
    ok "PHP $ver: $ext enabled"
}
