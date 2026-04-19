#!/usr/bin/env bash
set -euo pipefail
if [[ -x "$HOME/.local/bin/typora-wait" ]]; then
    echo "  ✓ typora-wait"
else
    echo "  ✗ typora-wait MISSING"
    exit 1
fi
