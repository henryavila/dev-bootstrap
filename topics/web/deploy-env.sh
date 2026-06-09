#!/usr/bin/env bash
# shellcheck disable=SC2034  # vars are consumed externally by deploy.sh envsubst (sourced with set -a)
# topics/web/deploy-env.sh — derive the env vars the web `serve` templates need.
#
# Sourced by the `deploy` driver (scripts/lib/installers/deploy.sh) with `set -a`
# before scripts/lib/deploy.sh renders the .template files via envsubst. Ported
# from the old setup.sh derive_nginx_conf_dir(), made self-contained so the
# engine can deploy the web bundles without setup.sh pre-deriving anything.
#
# Substituted vars (must match deploy.sh ENVSUBST_ALLOWLIST):
#   NGINX_AVAILABLE_DIR NGINX_ENABLED_DIR NGINX_SNIPPET_DIR NGINX_MAP_DIR
#   CERT_DIR CODE_DIR DEV_DEFAULT_PORT PHP_DEFAULT
#
# OS comes from $MESH_OS (exported by install-engine); brew prefix is detected
# on mac via scripts/lib/detect-brew.sh.

_web_os="${MESH_OS:-}"
if [ -z "$_web_os" ]; then
    case "$(uname -s)" in
        Darwin) _web_os=mac ;;
        Linux)  if grep -qi microsoft /proc/version 2>/dev/null; then _web_os=wsl; else _web_os=linux; fi ;;
        *)      _web_os=unknown ;;
    esac
fi

# Resolve brew prefix on mac (best-effort; empty elsewhere or when brew absent).
_web_brew_prefix="${BREW_PREFIX:-}"
if [ "$_web_os" = mac ] && [ -z "$_web_brew_prefix" ]; then
    # Prefer the engine-exported lib dir; fall back to a topic-relative path
    # for standalone deploy.sh runs.
    _web_lib="${MESH_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib" 2>/dev/null && pwd)}"
    if [ -n "$_web_lib" ] && _web_out="$(bash "$_web_lib/detect-brew.sh" 2>/dev/null)"; then
        eval "$_web_out"   # sets BREW_BIN / BREW_PREFIX
        _web_brew_prefix="${BREW_PREFIX:-}"
    fi
fi

# `${VAR:-default}` so a value already exported (by setup.sh, a test harness, or
# a re-run) is honored and not clobbered; only fall back to the OS-derived path.
case "$_web_os" in
    wsl|linux)
        NGINX_AVAILABLE_DIR="${NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
        NGINX_ENABLED_DIR="${NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
        NGINX_SNIPPET_DIR="${NGINX_SNIPPET_DIR:-/etc/nginx/snippets}"
        NGINX_MAP_DIR="${NGINX_MAP_DIR:-/etc/nginx/conf.d}"
        CERT_DIR="${CERT_DIR:-/etc/nginx/certs}"
        ;;
    mac)
        if [ -n "$_web_brew_prefix" ]; then
            NGINX_AVAILABLE_DIR="${NGINX_AVAILABLE_DIR:-$_web_brew_prefix/etc/nginx/servers-available}"
            NGINX_ENABLED_DIR="${NGINX_ENABLED_DIR:-$_web_brew_prefix/etc/nginx/servers}"
            NGINX_SNIPPET_DIR="${NGINX_SNIPPET_DIR:-$_web_brew_prefix/etc/nginx/snippets}"
            NGINX_MAP_DIR="${NGINX_MAP_DIR:-$_web_brew_prefix/etc/nginx/conf.d}"
            CERT_DIR="${CERT_DIR:-$_web_brew_prefix/etc/nginx/certs}"
        fi
        ;;
esac

# Alias kept for templates that still reference $NGINX_CONF_DIR (== sites-enabled).
NGINX_CONF_DIR="${NGINX_ENABLED_DIR:-}"

CODE_DIR="${CODE_DIR:-$HOME/code}"
DEV_DEFAULT_PORT="${DEV_DEFAULT_PORT:-3000}"
# PHP_DEFAULT comes from the languages/php option (params.env, exported by the
# engine). Leave whatever is already set; do not clobber.
PHP_DEFAULT="${PHP_DEFAULT:-}"
