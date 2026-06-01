#!/usr/bin/env bash
# Delegate to existing scripts/configure-windows-terminal.sh (Catppuccin
# theme + CaskaydiaCove Nerd Font via jq merge into Windows-side settings.json).

check() {
    # No deterministic post-config check; treat as needs-run on each invocation.
    return 1
}

install() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local script="$here/../scripts/configure-windows-terminal.sh"
    if [[ -x "$script" ]]; then
        bash "$script" \
            || echo "[windows-terminal-config] config failed (non-fatal)" >&2
    else
        echo "[windows-terminal-config] $script not executable — skipping" >&2
    fi
}

verify() {
    return 0
}

rollback() {
    :
}
