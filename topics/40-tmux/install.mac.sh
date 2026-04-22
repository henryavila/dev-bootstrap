#!/usr/bin/env bash
# 40-tmux (mac): tmux + TPM + Catppuccin theme plugin.
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

# ─── TPM (tmux plugin manager) ─────────────────────────────────────────
# Parity with install.wsl.sh: same path (~/.tmux/plugins/tpm) so
# tmux.conf is identical across platforms. Idempotent.
TPM_DIR="$HOME/.tmux/plugins/tpm"
if [ -d "$TPM_DIR/.git" ]; then
    info "TPM already cloned — pulling updates"
    git -C "$TPM_DIR" pull --quiet --ff-only 2>/dev/null \
        && ok "TPM up to date" \
        || warn "TPM pull failed (non-fatal)"
else
    info "cloning TPM → $TPM_DIR"
    mkdir -p "$HOME/.tmux/plugins"
    git clone --quiet --depth 1 https://github.com/tmux-plugins/tpm "$TPM_DIR"
    ok "TPM cloned"
fi

# ─── Catppuccin tmux (v1.0.3, pre-cloned into TPM path) ───────────────
# Same pin as Linux — see install.wsl.sh for rationale.
CATP_TMUX="$HOME/.tmux/plugins/tmux"
CATP_TAG="v1.0.3"
if [ -d "$CATP_TMUX/.git" ]; then
    current_ref="$(git -C "$CATP_TMUX" describe --tags --exact-match 2>/dev/null || true)"
    case "$current_ref" in
        v1|v1.0.3)  ok "catppuccin-tmux pinned to $current_ref" ;;
        "")         info "catppuccin-tmux on a non-tagged commit — leaving as-is" ;;
        *)          info "catppuccin-tmux on tag $current_ref — leaving as-is" ;;
    esac
else
    info "cloning catppuccin/tmux $CATP_TAG → $CATP_TMUX"
    git clone --quiet --depth 1 --branch "$CATP_TAG" \
        https://github.com/catppuccin/tmux "$CATP_TMUX"
    ok "catppuccin-tmux cloned"
fi

ok "40-tmux done"
