#!/usr/bin/env bash
# Custom installer: gh CLI on WSL/Ubuntu.
# Ubuntu 24.04+ ships gh in default apt (2.88+); older Ubuntu (20.04/22.04)
# need the GitHub APT repo fallback. Wrapped here so the engine's `apt`
# driver doesn't have to encode the conditional.

check() {
    command -v gh >/dev/null 2>&1
}

install() {
    if apt-cache show gh >/dev/null 2>&1; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq gh
    else
        # Fallback: add GitHub's official APT repo (older distros).
        sudo mkdir -p -m 755 /etc/apt/keyrings
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
        sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
        sudo apt-get update -qq
        sudo apt-get install -y -qq gh
    fi
}

verify() {
    check
}

rollback() {
    if dpkg -s gh >/dev/null 2>&1; then
        sudo apt-get remove -y -qq gh 2>/dev/null || true
    fi
    # Don't remove the APT repo entry — other tools or future installs may need it.
}
