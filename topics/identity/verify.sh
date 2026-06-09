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

# Align with identity-setup.sh check(): an SSH key is either id_ed25519 OR
# id_rsa. Derive the .pub from whichever private key exists (prefer ed25519).
ssh_key=""
if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
    ssh_key="$HOME/.ssh/id_ed25519"
elif [[ -f "$HOME/.ssh/id_rsa" ]]; then
    ssh_key="$HOME/.ssh/id_rsa"
fi

check "gh installed"              "command -v gh"
check "gh authenticated"          "gh auth status"
check "SSH key exists"            "test -n \"$ssh_key\""
check "SSH key registered on GH"  "gh ssh-key list | grep -q \"\$(ssh-keygen -lf $ssh_key.pub | awk '{print \$2}')\""
check "SSH auth to GitHub"        "ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new git@github.com 2>&1 | grep -q authenticated"

[[ "$fail_count" -eq 0 ]]
