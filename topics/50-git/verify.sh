#!/usr/bin/env bash
set -euo pipefail

fail_count=0
check() {
    local key="$1" expected="$2"
    local actual
    actual="$(git config --global --get "$key" 2>/dev/null || true)"
    if [[ "$actual" == "$expected" ]]; then
        echo "  ✓ $key = $expected"
    else
        echo "  ✗ $key = '$actual' (expected '$expected')"
        fail_count=$((fail_count + 1))
    fi
}

check init.defaultBranch main
check core.pager delta
check merge.conflictstyle zdiff3
check pull.rebase false
check push.autoSetupRemote true

[[ "$fail_count" -eq 0 ]]
