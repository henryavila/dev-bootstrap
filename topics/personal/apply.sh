#!/usr/bin/env bash
# personal/apply: clone $MESH_IDENTITY_REPO + run its install.sh.
# Custom item contract — engine sources this and calls check()/install()/verify().
# Marked idempotent in the manifest: the identity repo is re-applied on every run
# (identity_ensure_repo pulls, the fork's install.sh is itself idempotent).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/log.sh"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/identity-repo.sh"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/topic-cleanup.sh"

check() {
    # Idempotent apply — always run (manifest idempotent: true). The identity
    # fork's own install.sh handles the "already applied" fast paths.
    return 1
}

install() { (
    set -euo pipefail

    : "${MESH_IDENTITY_REPO:?set the mesh-identity repo in the 'Personal identity' options (or export MESH_IDENTITY_REPO). Create-from-template onboarding is pending — see initiative.}"
    : "${MESH_IDENTITY_DIR:=$HOME/mesh-identity}"

    identity_ensure_repo "$MESH_IDENTITY_REPO" "$MESH_IDENTITY_DIR"

    if [[ -f "$MESH_IDENTITY_DIR/install.sh" ]]; then
        info "running $MESH_IDENTITY_DIR/install.sh"
        MESH_NPM_GLOBAL="${MESH_NPM_GLOBAL:-0}" bash "$MESH_IDENTITY_DIR/install.sh"
    else
        warn "$MESH_IDENTITY_DIR/install.sh not found — identity repo cloned but not applied"
    fi

    # Drift cleanup: artifacts the identity fork used to install but no longer
    # does. Reads data/uninstall.list and removes each entry. Idempotent.
    uninstall_apply "$HERE/data/uninstall.list"

    ok "personal identity done"
) }

verify() {
    [ -d "${MESH_IDENTITY_DIR:-$HOME/mesh-identity}" ]
}

rollback() {
    # Never auto-remove the user's applied identity layer.
    :
}
