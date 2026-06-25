# shellcheck shell=bash

cmd_init_run() {
    local lib
    lib="$(_resolve_companion "lib/init.sh")"
    [[ -n "$lib" ]] || _die "lib/init.sh not found (set \$MESH_HOME or check installation)"
    exec bash "$lib" "$@"
}

mesh_register_command \
    --name init \
    --summary "Bootstrap identity on a fresh machine" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_init_run
