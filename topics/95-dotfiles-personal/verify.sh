#!/usr/bin/env bash
set -euo pipefail
: "${DOTFILES_DIR:=$HOME/dotfiles}"
if [[ -d "$DOTFILES_DIR/.git" ]]; then
    echo "  ✓ $DOTFILES_DIR (git repo)"
else
    echo "  ✗ $DOTFILES_DIR MISSING"
    exit 1
fi
