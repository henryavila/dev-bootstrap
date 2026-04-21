#!/usr/bin/env bash
# 40-tmux (WSL): tmux + Catppuccin theme plugin.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

if dpkg -s tmux >/dev/null 2>&1; then
    ok "tmux already installed"
else
    info "apt install tmux"
    sudo apt-get update -qq
    sudo apt-get install -y -qq tmux
fi

# ─── Catppuccin tmux (v1.0.3, simple @catppuccin_flavour API) ─────────
# Pinned to v1 because v2 introduced a module-based API that'd require
# a bigger tmux.conf rewrite for marginal gain. Upgrade later by
# re-running this script after bumping the branch reference.
CATP_TMUX="$HOME/.local/share/catppuccin-tmux"
CATP_TAG="v1.0.3"
if [ -d "$CATP_TMUX/.git" ]; then
    if git -C "$CATP_TMUX" describe --tags --exact-match 2>/dev/null | grep -q "^$CATP_TAG$"; then
        ok "catppuccin-tmux already at $CATP_TAG"
    else
        info "catppuccin-tmux present but on a different ref — leaving as-is (manual review)"
    fi
else
    info "cloning catppuccin/tmux $CATP_TAG → $CATP_TMUX"
    git clone --quiet --depth 1 --branch "$CATP_TAG" \
        https://github.com/catppuccin/tmux "$CATP_TMUX"
    ok "catppuccin-tmux cloned"
fi

ok "40-tmux done"
