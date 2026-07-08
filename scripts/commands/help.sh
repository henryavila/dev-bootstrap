# shellcheck shell=bash

cmd_help_run() {
    local runner
    runner="$(_resolve_companion "runners/help.sh")"
    [[ -n "$runner" ]] || _die "runners/help.sh not found (set \$MESH_HOME or check installation)"
    exec bash "$runner" "$@"
}

mesh_register_command \
    --name help \
    --summary "Browse command help" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_help_run
