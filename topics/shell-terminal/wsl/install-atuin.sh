#!/usr/bin/env bash
# atuin lands in ~/.atuin/bin (official installer), which is NOT on the engine
# item-subshell PATH on WSL — fall back to the absolute path so post-verify holds.
check() { command -v atuin >/dev/null 2>&1 || [[ -x "$HOME/.atuin/bin/atuin" ]]; }

install() {
    if [[ "${NON_INTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
        curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh -s -- --non-interactive
    else
        curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh
    fi
}

verify()  { check; }
rollback() {
    local dir="$HOME/.atuin"
    [[ -d "$dir" ]] && rm -rf "$dir"
}
