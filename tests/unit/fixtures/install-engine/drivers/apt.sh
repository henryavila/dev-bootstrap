#!/usr/bin/env bash
# Minimal apt driver stub for P4 test.
# shellcheck disable=SC2034  # driver metadata read by the engine when sourced
DRIVER_APT_PLATFORMS="linux"

install_apt() {
    local spec="$1"
    info "install_apt called with: $spec"
    printf 'install_apt %s\n' "$spec" >> "${MESH_STATE_FILE:-/dev/null}"
    return 0
}
