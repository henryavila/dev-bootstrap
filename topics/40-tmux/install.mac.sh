#!/usr/bin/env bash
# 40-tmux (mac): tmux + Catppuccin theme plugin.
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

# ─── Catppuccin tmux (v1.0.3, simple @catppuccin_flavour API) ─────────
# Same clone path as Linux so tmux.conf's run-shell line is identical
# across platforms. Pinned to v1 — see install.wsl.sh for rationale.
CATP_TMUX="$HOME/.local/share/catppuccin-tmux"
CATP_TAG="v1.0.3"
if [ -d "$CATP_TMUX/.git" ]; then
    if git -C "$CATP_TMUX" describe --tags --exact-match 2>/dev/null | grep -q "^$CATP_TAG$"; then
        ok "catppuccin-tmux already at $CATP_TAG"
    else
        info "catppuccin-tmux present but on a different ref — leaving as-is"
    fi
else
    info "cloning catppuccin/tmux $CATP_TAG → $CATP_TMUX"
    git clone --quiet --depth 1 --branch "$CATP_TAG" \
        https://github.com/catppuccin/tmux "$CATP_TMUX"
    ok "catppuccin-tmux cloned"
fi

ok "40-tmux done"
