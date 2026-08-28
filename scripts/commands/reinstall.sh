# shellcheck shell=bash

cmd_reinstall_run() {
    local runner
    runner="$(_resolve_companion "runners/reinstall.sh")"
    [[ -n "$runner" ]] || _die "runners/reinstall.sh not found (set \$MESH_HOME or check installation)"
    exec bash "$runner" "$@"
}

mesh_register_command \
    --name reinstall \
    --summary "Reapply the shell layer without touching services" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_reinstall_run
