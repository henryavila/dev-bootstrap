#!/usr/bin/env bash
set -euo pipefail

fail_count=0
check() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then
        echo "  ✓ $name"
    else
        echo "  ✗ $name MISSING"
        fail_count=$((fail_count + 1))
    fi
}

check fzf
check bat || check batcat
check eza
check zoxide
check rg
check fd || check fdfind
check starship
check lazygit
check delta

[[ "$fail_count" -eq 0 ]]
