#!/usr/bin/env bash
# Custom installer: Claude Code CLI.

check() {
    command -v claude >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/claude" ]]
}

install() {
    curl -fsSL https://claude.ai/install.sh | bash
    PATH="$HOME/.local/bin:$PATH"; export PATH
}

verify() {
    check
}

rollback() {
    if [[ -x "$HOME/.local/bin/claude" ]]; then
        rm -f "$HOME/.local/bin/claude"
    fi
}
