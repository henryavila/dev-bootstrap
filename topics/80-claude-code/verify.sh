#!/usr/bin/env bash
set -euo pipefail
# Ensure ~/.local/bin in PATH for CI where new shell hasn't loaded ~/.bashrc
[[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
if command -v claude >/dev/null 2>&1; then
    echo "  ✓ claude"
else
    echo "  ✗ claude MISSING"
    exit 1
fi
