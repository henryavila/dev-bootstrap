#!/usr/bin/env bash
# Custom installer: Claude Code CLI.

check() {
    command -v claude >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/claude" ]]
}

install() {
    # pipefail so a failed curl is reported as install failure, not masked by bash's rc 0
    ( set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash )
}

verify() {
    check
}

rollback() {
    if [[ -x "$HOME/.local/bin/claude" ]]; then
        rm -f "$HOME/.local/bin/claude"
    fi
}
