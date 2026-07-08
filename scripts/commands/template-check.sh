# shellcheck shell=bash

cmd_template_check_run() {
    local lib
    lib="$(_resolve_companion "lib/template-check.sh")"
    [[ -n "$lib" ]] || _die "lib/template-check.sh not found (set \$MESH_HOME or check installation)"
    exec bash "$lib" "$@"
}

mesh_register_command \
    --name template-check \
    --summary "Verify template and identity parity" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_template_check_run
