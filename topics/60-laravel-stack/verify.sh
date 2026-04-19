#!/usr/bin/env bash
set -euo pipefail

fail_count=0
check() {
    if command -v "$1" >/dev/null 2>&1; then
        echo "  ✓ $1"
    else
        echo "  ✗ $1 MISSING"
        fail_count=$((fail_count + 1))
    fi
}
check mysql
check redis-cli
check nginx
check mkcert

[[ "$fail_count" -eq 0 ]]
