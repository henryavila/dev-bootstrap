#!/usr/bin/env bash
# install-postgres.sh — P4 custom script POC (spec.md §C18 escape hatch).
#
# Engine pre-sources log.sh + env.sh + ALL drivers before sourcing this file.
# All 4 lifecycle functions run in subshell isolation: `( source script; check )`.

# --- Required by contract ---

check() {
    # Mock: read state to see if "install_brew postgresql@17" recorded.
    if [ -f "${MESH_STATE_FILE:-/dev/null}" ] && \
       grep -q "postgresql@17\|postgresql-17" "${MESH_STATE_FILE:-/dev/null}" 2>/dev/null; then
        return 0
    fi
    return 1
}

install() {
    # C6 fix: canary set unconditionally so leak detection works on both
    # platforms (previously only set in linux branch via _add_pgdg_repo).
    POSTGRES_INTERNAL_LEAK_CANARY="if-you-see-this-in-engine-isolation-failed"
    case "$MESH_OS" in
        mac)
            info "postgres install path: brew (Mac)"
            install_brew "postgresql@17"
            ;;
        linux)
            info "postgres install path: apt + PGDG (Linux)"
            _add_pgdg_repo && install_apt "postgresql-17"
            ;;
        *)
            err "unsupported platform: $MESH_OS"
            return 1
            ;;
    esac
}

# --- Optional ---

verify() {
    # Mock: just confirm state file got the line.
    grep -q 'postgresql' "${MESH_STATE_FILE:-/dev/null}" 2>/dev/null
}

rollback() {
    warn "rolling back postgres install (mock)"
    # In real life: brew uninstall --ignore-dependencies postgresql@17, etc.
    # Mock: append rollback marker.
    printf 'rollback postgres\n' >> "${MESH_STATE_FILE:-/dev/null}"
}

# --- Private helpers (these must NOT leak to engine after subshell exits) ---

_add_pgdg_repo() {
    info "(mock) adding PGDG APT repo"
    POSTGRES_INTERNAL_LEAK_CANARY="if-you-see-this-in-engine-isolation-failed"
    return 0
}
