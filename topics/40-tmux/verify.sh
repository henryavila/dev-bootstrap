#!/usr/bin/env bash
set -euo pipefail
if command -v tmux >/dev/null 2>&1; then
    echo "  ✓ tmux ($(tmux -V))"
    [[ -f "$HOME/.tmux.conf" ]] && echo "  ✓ ~/.tmux.conf" || { echo "  ✗ ~/.tmux.conf MISSING"; exit 1; }
else
    echo "  ✗ tmux MISSING"
    exit 1
fi
