# shellcheck shell=bash

cmd_secret_run() {
    local lib
    lib="$(_resolve_companion "lib/secret.sh")"
    [[ -n "$lib" ]] || _die "lib/secret.sh not found (set \$MESH_HOME or check installation)"
    exec bash "$lib" "$@"
}

mesh_register_command \
    --name secret \
    --summary "Manage replicated personal secrets" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_secret_run
