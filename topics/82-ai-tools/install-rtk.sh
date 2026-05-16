#!/usr/bin/env bash
# Custom installer for rtk (Rust Token Killer).
# Engine sources this file inside a subshell and calls install(), check(), verify().
# All four functions defined here; engine's custom driver dispatches them.

check() {
    # Guard against name collision with reachingforthejack/rtk (Rust Type Kit):
    # The real rtk must respond to `rtk gain --help` (Rust Type Kit does not).
    command -v rtk >/dev/null 2>&1 || return 1
    rtk gain >/dev/null 2>&1
}

install() {
    curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh | sh
    # Ensure newly installed binary is on PATH for immediate verify step.
    PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
    export PATH
}

verify() {
    check
}

rollback() {
    # rtk does not provide an uninstall command; remove the binary if found.
    local bin
    bin="$(command -v rtk 2>/dev/null || true)"
    [[ -n "$bin" ]] && rm -f "$bin" || true
}
