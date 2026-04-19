#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

: "${BREW_BIN:?BREW_BIN not set — run through bootstrap.sh}"

if "$BREW_BIN" list --formula tmux >/dev/null 2>&1; then
    ok "tmux already installed"
else
    info "brew install tmux"
    "$BREW_BIN" install tmux
fi

ok "40-tmux done"
