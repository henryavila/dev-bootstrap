#!/usr/bin/env bash
# 82-ai-tools: install AI tools from the dotfiles manifest without applying
# personal dotfiles.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"
# shellcheck disable=SC1091
source "$HERE/../../lib/dotfiles-repo.sh"

: "${DOTFILES_REPO:?DOTFILES_REPO not set (required for the AI tools manifest)}"
: "${DOTFILES_DIR:=$HOME/dotfiles}"

dotfiles_ensure_repo "$DOTFILES_REPO" "$DOTFILES_DIR"

ai_installer="$DOTFILES_DIR/scripts/install-ai-packages.sh"
if [[ ! -f "$ai_installer" ]]; then
    fail "$ai_installer not found — dotfiles repo does not expose the AI package installer"
    exit 1
fi

info "running dotfiles AI package installer"
DOTFILES_AI_PACKAGES=1 bash "$ai_installer"

ok "82-ai-tools done"
