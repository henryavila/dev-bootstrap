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

if [[ -z "${MESH_WORKSTATION_DIR:-}" && -z "${MESH_IDENTITY_DIR:-}" ]]; then
    _mesh_env_load_config
fi
: "${MESH_WORKSTATION_DIR:=${HOME}/mesh-workstation}"
: "${MESH_IDENTITY_DIR:=${HOME}/mesh-identity}"

export MESH_WORKSTATION_DIR MESH_IDENTITY_DIR
