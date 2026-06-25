# shellcheck shell=bash

cmd_config_run() {
    local runner
    runner="$(_resolve_companion "runners/config.sh")"
    [[ -n "$runner" ]] || _die "runners/config.sh not found (set \$MESH_HOME or check installation)"
    exec bash "$runner" "$@"
}

mesh_register_command \
    --name config \
    --summary "Edit personal config from mesh-identity" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_config_run
