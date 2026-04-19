#!/usr/bin/env bash
# 95-dotfiles-personal: clone $DOTFILES_REPO into $DOTFILES_DIR and run its install.sh.
# Gated by bootstrap.sh: skipped when DOTFILES_REPO is empty.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

: "${DOTFILES_REPO:?DOTFILES_REPO not set (bootstrap.sh should have skipped this topic)}"
: "${DOTFILES_DIR:=$HOME/dotfiles}"

if [[ -d "$DOTFILES_DIR/.git" ]]; then
    info "pulling updates in $DOTFILES_DIR"
    git -C "$DOTFILES_DIR" pull --ff-only || warn "could not fast-forward; leaving as-is"
else
    if [[ -e "$DOTFILES_DIR" ]]; then
        fail "$DOTFILES_DIR exists and is not a git repo — move or delete it first"
        exit 1
    fi
    info "cloning $DOTFILES_REPO → $DOTFILES_DIR"
    git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
fi

if [[ -f "$DOTFILES_DIR/install.sh" ]]; then
    info "running $DOTFILES_DIR/install.sh"
    bash "$DOTFILES_DIR/install.sh"
else
    warn "$DOTFILES_DIR/install.sh not found — dotfiles cloned but not applied"
fi

ok "95-dotfiles-personal done"
