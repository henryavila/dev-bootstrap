#!/usr/bin/env bash
# Delegate to existing scripts/generate-zsh-completions.sh.

check() {
    return 1   # always re-run; underlying script is idempotent and cheap
}

install() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local script="$here/scripts/generate-zsh-completions.sh"
    if [[ -x "$script" ]]; then
        bash "$script" \
            || echo "[generate-completions] script returned non-zero (non-fatal)" >&2
    fi
}

verify() {
    return 0
}

rollback() {
    :
}
