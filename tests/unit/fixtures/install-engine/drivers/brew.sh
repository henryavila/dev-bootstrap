#!/usr/bin/env bash
# Minimal brew driver stub for P4 test — does not invoke real brew.
DRIVER_BREW_PLATFORMS="mac"

install_brew() {
    local spec="$1"
    # Mock: log to state file so test can assert what would have been installed.
    info "install_brew called with: $spec"
    printf 'install_brew %s\n' "$spec" >> "${MESH_STATE_FILE:-/dev/null}"
    return 0
}
