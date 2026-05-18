#!/usr/bin/env bash
check() { command -v atuin >/dev/null 2>&1; }

install() {
    if [[ -t 0 ]]; then
        curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh
    else
        curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh -s -- --non-interactive
    fi
}

verify()  { check; }
rollback() {
    local dir="$HOME/.atuin"
    [[ -d "$dir" ]] && rm -rf "$dir"
}
