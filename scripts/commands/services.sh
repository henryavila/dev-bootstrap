# shellcheck shell=bash

cmd_services_run() {
    local runner
    runner="$(_resolve_companion "runners/services.sh")"
    [[ -n "$runner" ]] || _die "runners/services.sh not found (set \$MESH_HOME or check installation)"
    export MESH_SERVICES_ALIAS="${MESH_SERVICES_ALIAS:-$(_mesh_self_alias)}"
    exec bash "$runner" "$@"
}

mesh_register_command \
    --name services \
    --summary "Control mesh-owned daemons" \
    --group core \
    --origin core \
    --visibility public \
    --fanout allowed \
    --handler cmd_services_run \
    --fanout-validator _mesh_fanout_validate_services \
    --fanout-env-provider _mesh_fanout_env_noninteractive
