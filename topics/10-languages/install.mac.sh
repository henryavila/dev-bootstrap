#!/usr/bin/env bash
# 10-languages (mac): Node via fnm (brew), PHP 8.4, Composer, Python current.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

: "${BREW_BIN:?BREW_BIN not set — run through bootstrap.sh}"

brew_install_if_missing() {
    local pkg="$1"
    if "$BREW_BIN" list --formula "$pkg" >/dev/null 2>&1; then
        ok "$pkg already installed"
    else
        info "brew install $pkg"
        "$BREW_BIN" install "$pkg"
    fi
}

brew_install_if_missing fnm
brew_install_if_missing php@8.4
brew_install_if_missing composer
brew_install_if_missing python@3.13

# PHP 8.4 is keg-only on macOS; link explicitly if not linked
if ! "$BREW_BIN" list --versions php@8.4 >/dev/null 2>&1; then
    :
else
    "$BREW_BIN" link --force --overwrite php@8.4 >/dev/null 2>&1 || true
fi

# fnm needs its shell init; handled by bashrc.d/zshrc.d fragments below.
# Still, install LTS now if absent.
eval "$("$BREW_PREFIX/bin/fnm" env)"
if "$BREW_PREFIX/bin/fnm" list 2>/dev/null | grep -qE '\bv[0-9]+\.[0-9]+\.[0-9]+'; then
    ok "Node already installed via fnm ($("$BREW_PREFIX/bin/fnm" current 2>/dev/null || echo '?'))"
else
    info "fnm install --lts"
    "$BREW_PREFIX/bin/fnm" install --lts
    default_ver="$("$BREW_PREFIX/bin/fnm" list | awk '/^\s*v[0-9]/ {print $NF}' | tail -1 || true)"
    [[ -n "$default_ver" ]] && "$BREW_PREFIX/bin/fnm" default "$default_ver" || true
fi

ok "10-languages done"
