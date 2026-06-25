# shellcheck shell=bash

cmd_snap_run() {
    local lib
    lib="$(_resolve_companion "internal/mesh-snap")"
    [[ -n "$lib" ]] || _die "internal/mesh-snap not found (set \$MESH_HOME or check installation)"
    exec "$lib" "$@"
}

mesh_register_command \
    --name snap \
    --summary "Generate this host snapshot" \
    --group core \
    --origin core \
    --visibility public \
    --fanout allowed \
    --handler cmd_snap_run \
    --fanout-validator _mesh_fanout_validate_any
