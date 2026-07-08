# shellcheck shell=bash

cmd_personal_clone_run() {
    local lib
    lib="$(_resolve_companion "lib/personal-clone.sh")"
    [[ -n "$lib" ]] || _die "lib/personal-clone.sh not found (set \$MESH_HOME or check installation)"
    exec bash "$lib" "$@"
}

mesh_register_command \
    --name personal-clone \
    --summary "Clone personal repos from identity catalog" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_personal_clone_run
