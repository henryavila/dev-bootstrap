#!/usr/bin/env bash
set -euo pipefail

fail_count=0

# check: pass/fail on a single command name.
check() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then
        echo "  ✓ $name"
    else
        echo "  ✗ $name MISSING"
        fail_count=$((fail_count + 1))
    fi
}

# check_any: pass if ANY of the names is found (used for tools shipped
# under different binary names per OS — `bat` (brew) vs `batcat` (apt),
# `fd` vs `fdfind`).
check_any() {
    local found=""
    for name in "$@"; do
        if command -v "$name" >/dev/null 2>&1; then
            found="$name"
            break
        fi
    done
    if [[ -n "$found" ]]; then
        echo "  ✓ $found"
    else
        echo "  ✗ $1 MISSING (tried: $*)"
        fail_count=$((fail_count + 1))
    fi
}

check fzf
check_any bat batcat
check eza
check zoxide
check rg
check_any fd fdfind
check starship
check lazygit
check delta
check tmux
check nvim
# Modern-CLI Phase E tools — warn only, not hard-fail. Missing them means
# the aliases in aliases.sh quietly fall back to the native counterpart.
for t in btop duf gping sd tldr dust xh procs; do
    if command -v "$t" >/dev/null 2>&1; then
        echo "  ✓ $t"
    else
        echo "  ! $t missing (aliases fall back to native tool)"
    fi
done

[[ "$fail_count" -eq 0 ]]
