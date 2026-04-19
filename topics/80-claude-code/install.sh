#!/usr/bin/env bash
# 80-claude-code: install the Claude Code CLI (cross-OS).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

if command -v claude >/dev/null 2>&1; then
    ok "claude already installed ($(claude --version 2>&1 | head -1))"
    exit 0
fi

info "installing Claude Code via official installer"
curl -fsSL https://claude.ai/install.sh | bash

if ! command -v claude >/dev/null 2>&1; then
    # Installer often puts binary under ~/.local/bin which 30-shell adds to PATH.
    if [[ -x "$HOME/.local/bin/claude" ]]; then
        ok "claude installed at ~/.local/bin/claude (open a new shell to pick it up)"
    else
        warn "claude not on PATH after install — check /tmp logs above"
        exit 1
    fi
else
    ok "claude installed ($(claude --version 2>&1 | head -1))"
fi
