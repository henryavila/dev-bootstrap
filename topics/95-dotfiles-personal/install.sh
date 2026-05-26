#!/usr/bin/env bash
# 95-dotfiles-personal: apply personal dotfiles from $MESH_IDENTITY_REPO.
# Gated by setup.sh: skipped unless INCLUDE_IDENTITY=1.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/log.sh"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/identity-repo.sh"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/topic-cleanup.sh"

: "${MESH_IDENTITY_REPO:?MESH_IDENTITY_REPO not set (setup.sh should have skipped this topic)}"
: "${MESH_IDENTITY_DIR:=$HOME/mesh-identity}"

identity_ensure_repo "$MESH_IDENTITY_REPO" "$MESH_IDENTITY_DIR"

if [[ -f "$MESH_IDENTITY_DIR/install.sh" ]]; then
    info "running $MESH_IDENTITY_DIR/install.sh"
    MESH_NPM_GLOBAL="${MESH_NPM_GLOBAL:-0}" bash "$MESH_IDENTITY_DIR/install.sh"
else
    warn "$MESH_IDENTITY_DIR/install.sh not found — dotfiles cloned but not applied"
fi

# Drift cleanup: artifacts the dotfiles fork used to install but no longer
# does. Reads data/uninstall.list and removes each entry. Idempotent.
# See header of data/uninstall.list for syntax.
uninstall_apply "$HERE/data/uninstall.list"

ok "95-dotfiles-personal done"
