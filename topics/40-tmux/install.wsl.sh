#!/usr/bin/env bash
# 40-tmux (WSL): tmux + TPM + Catppuccin theme plugin.
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

# ─── TPM (tmux plugin manager) ─────────────────────────────────────────
# Canonical path ~/.tmux/plugins/tpm — that's where every TPM-aware
# tmux.conf (including ours) expects it. Idempotent: pull if present.
# Plugins declared in tmux.conf via `set -g @plugin '<owner>/<name>'`;
# `prefix + I` installs them inside a live tmux session. We also pre-
# clone catppuccin below so the theme is live on the very first launch.
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
# Pinned to v1: v2 changed to a module-based API that'd need a tmux.conf
# rewrite. `prefix + U` through TPM respects the `#v1.0.3` suffix in the
# tmux.conf @plugin line.
CATP_TMUX="$HOME/.tmux/plugins/tmux"
CATP_TAG="v1.0.3"
if [ -d "$CATP_TMUX/.git" ]; then
    current_ref="$(git -C "$CATP_TMUX" describe --tags --exact-match 2>/dev/null || true)"
    case "$current_ref" in
        v1|v1.0.3)  ok "catppuccin-tmux pinned to $current_ref" ;;
        "")         info "catppuccin-tmux on a non-tagged commit — leaving as-is" ;;
        *)          info "catppuccin-tmux on tag $current_ref — leaving as-is (manual review)" ;;
    esac
else
    info "cloning catppuccin/tmux $CATP_TAG → $CATP_TMUX"
    git clone --quiet --depth 1 --branch "$CATP_TAG" \
        https://github.com/catppuccin/tmux "$CATP_TMUX"
    ok "catppuccin-tmux cloned"
fi

# Legacy clone from the pre-TPM layout. Nothing sources it anymore.
# Safe to remove; kept here commented so the rm is explicit when you
# want to reclaim ~600KB.
# rm -rf "$HOME/.local/share/catppuccin-tmux" 2>/dev/null || true

ok "40-tmux done"
