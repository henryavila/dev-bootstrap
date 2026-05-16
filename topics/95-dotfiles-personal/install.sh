#!/usr/bin/env bash
# 95-dotfiles-personal: apply personal dotfiles from $DOTFILES_REPO.
# Gated by setup.sh: skipped unless INCLUDE_DOTFILES_PERSONAL=1.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"
# shellcheck disable=SC1091
source "$HERE/../../lib/dotfiles-repo.sh"
# shellcheck disable=SC1091
source "$HERE/../../lib/uninstall.sh"

: "${DOTFILES_REPO:?DOTFILES_REPO not set (setup.sh should have skipped this topic)}"
: "${DOTFILES_DIR:=$HOME/dotfiles}"

dotfiles_ensure_repo "$DOTFILES_REPO" "$DOTFILES_DIR"

if [[ -f "$DOTFILES_DIR/install.sh" ]]; then
    info "running $DOTFILES_DIR/install.sh"
    DOTFILES_NPM_GLOBAL="${DOTFILES_NPM_GLOBAL:-0}" bash "$DOTFILES_DIR/install.sh"
else
    warn "$DOTFILES_DIR/install.sh not found — dotfiles cloned but not applied"
fi

# Drift cleanup: artifacts the dotfiles fork used to install but no longer
# does. Reads data/uninstall.list and removes each entry. Idempotent.
# See header of data/uninstall.list for syntax.
uninstall_apply "$HERE/data/uninstall.list"

ok "95-dotfiles-personal done"
