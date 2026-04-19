#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

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

for cmd in git curl wget jq unzip envsubst gpg; do
    check "$cmd"
done

if [[ "$fail_count" -gt 0 ]]; then
    exit 1
fi
