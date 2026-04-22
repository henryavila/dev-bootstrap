#!/usr/bin/env bash
set -euo pipefail

fail_count=0
check() {
    local name="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        echo "  ✓ $name"
    else
        echo "  ✗ $name"
        fail_count=$((fail_count + 1))
    fi
}

check "gh installed"              "command -v gh"
check "gh authenticated"          "gh auth status"
check "SSH key exists"            "test -f $HOME/.ssh/id_ed25519"
check "SSH key registered on GH"  "gh ssh-key list | grep -q \"\$(ssh-keygen -lf $HOME/.ssh/id_ed25519.pub | awk '{print \$2}')\""
check "SSH auth to GitHub"        "ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new git@github.com 2>&1 | grep -q authenticated"

[[ "$fail_count" -eq 0 ]]
