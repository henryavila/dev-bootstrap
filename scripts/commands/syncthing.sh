# shellcheck shell=bash

cmd_syncthing_run() {
    local runner
    runner="$(_resolve_companion "runners/syncthing.sh")"
    [[ -n "$runner" ]] || _die "runners/syncthing.sh not found (set \$MESH_HOME or check installation)"
    exec bash "$runner" "$@"
}

mesh_register_command \
    --name syncthing \
    --summary "Pair this node into the Syncthing mesh" \
    --group core \
    --origin core \
    --visibility public \
    --fanout allowed \
    --handler cmd_syncthing_run \
    --fanout-validator _mesh_fanout_validate_syncthing \
    --fanout-env-provider _mesh_fanout_env_noninteractive
