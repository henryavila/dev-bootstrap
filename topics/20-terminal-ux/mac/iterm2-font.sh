#!/usr/bin/env bash
# Delegate to existing scripts/configure-iterm2-font.sh.
SCRIPT_REL="../scripts/configure-iterm2-font.sh"

check() {
    # iTerm2 not installed → no-op pass.
    [[ -d "/Applications/iTerm.app" ]] || return 0
    # We don't have a deterministic post-config check; treat as needs-run.
    return 1
}

install() {
    [[ -d "/Applications/iTerm.app" ]] || return 0
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -x "$here/$SCRIPT_REL" ]]; then
        bash "$here/$SCRIPT_REL" \
            || echo "[iterm2-font] config failed (non-fatal)" >&2
    fi
}

verify() {
    return 0
}

rollback() {
    :
}
