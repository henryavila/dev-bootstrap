#!/usr/bin/env bash
# 05-identity (Mac): gh CLI + SSH key + GitHub registration.
# Runs BEFORE 95-dotfiles-personal so the private dotfiles clone works.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

: "${BREW_BIN:?BREW_BIN not set — run through bootstrap.sh}"

if "$BREW_BIN" list --formula gh >/dev/null 2>&1; then
    ok "gh already installed ($(gh --version | head -1))"
else
    info "brew install gh"
    "$BREW_BIN" install gh
fi

bash "$HERE/scripts/setup-identity.sh"

ok "05-identity done"
