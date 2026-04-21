#!/usr/bin/env bash
set -euo pipefail

fail=0

if [[ -x "$HOME/.local/bin/typora-wait" ]]; then
    echo "  ✓ typora-wait  (blocking — for \$EDITOR usage)"
else
    echo "  ✗ typora-wait MISSING"
    fail=1
fi

if [[ -x "$HOME/.local/bin/typora" ]]; then
    echo "  ✓ typora  (non-blocking — quick open)"
else
    echo "  ✗ typora MISSING"
    fail=1
fi

[[ "$fail" == 0 ]] || exit 1
