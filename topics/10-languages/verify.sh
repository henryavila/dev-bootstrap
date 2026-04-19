#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

# fnm may not be in PATH in a fresh shell during CI; try known locations.
for p in "$HOME/.local/share/fnm" "/opt/homebrew/bin" "/usr/local/bin"; do
    [[ -d "$p" ]] && export PATH="$p:$PATH"
done
if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env 2>/dev/null || true)"
fi

fail_count=0
check() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then
        echo "  ✓ $name ($($name --version 2>&1 | head -1))"
    else
        echo "  ✗ $name MISSING"
        fail_count=$((fail_count + 1))
    fi
}

check fnm
check node
check php
check composer
check python3

[[ "$fail_count" -eq 0 ]]
