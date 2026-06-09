# shellcheck shell=bash
# scripts/lib/env.sh — resolve MESH_WORKSTATION_DIR / MESH_IDENTITY_DIR.
# Source-only. Idempotent: re-sourcing leaves already-set values alone.
#
# Resolution chain (first that yields a value wins):
#   1. Environment variable already set
#   2. ~/.config/mesh/config.env (key=value lines)
#   3. Fallback to ~/mesh-{workstation,identity}

_mesh_env_load_config() {
    local cfg="${HOME}/.config/mesh/config.env"
    [[ -r "$cfg" ]] || return 0
    # shellcheck disable=SC1090
    . "$cfg"
}

# Consult config.env whenever EITHER var is unset — it may hold the one that's
# missing (e.g. a host whose workstation lives at a non-default path, where only
# MESH_IDENTITY_DIR happened to be set in the environment). config.env uses
# plain KEY=value assignment, so snapshot any caller-set values first and
# restore them afterward: config fills the gaps but never clobbers an explicit
# env var. (The previous `&&` guard skipped config entirely if EITHER var was
# set, which silently broke workstation-path resolution on this host.)
_mesh_pre_ws="${MESH_WORKSTATION_DIR:-}"
_mesh_pre_id="${MESH_IDENTITY_DIR:-}"
if [[ -z "$_mesh_pre_ws" || -z "$_mesh_pre_id" ]]; then
    _mesh_env_load_config
fi
if [[ -n "$_mesh_pre_ws" ]]; then MESH_WORKSTATION_DIR="$_mesh_pre_ws"; fi
if [[ -n "$_mesh_pre_id" ]]; then MESH_IDENTITY_DIR="$_mesh_pre_id"; fi
unset _mesh_pre_ws _mesh_pre_id
: "${MESH_WORKSTATION_DIR:=${HOME}/mesh-workstation}"
: "${MESH_IDENTITY_DIR:=${HOME}/mesh-identity}"

export MESH_WORKSTATION_DIR MESH_IDENTITY_DIR
