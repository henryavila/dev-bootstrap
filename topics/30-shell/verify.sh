#!/usr/bin/env bash
set -euo pipefail

fail_count=0
check_dir() {
    if [[ -d "$1" ]]; then
        echo "  ✓ $1"
    else
        echo "  ✗ $1 MISSING"
        fail_count=$((fail_count + 1))
    fi
}
check_file_loads_dir() {
    local rc="$1" dir="$2"
    if [[ -f "$rc" ]] && grep -q "$dir" "$rc"; then
        echo "  ✓ $rc loads $dir"
    else
        echo "  ✗ $rc does not load $dir"
        fail_count=$((fail_count + 1))
    fi
}

check_dir "$HOME/.bashrc.d"
check_dir "$HOME/.zshrc.d"
check_file_loads_dir "$HOME/.bashrc" '.bashrc.d'
check_file_loads_dir "$HOME/.zshrc"  '.zshrc.d'

[[ "$fail_count" -eq 0 ]]
