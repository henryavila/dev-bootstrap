# shellcheck shell=bash

cmd_clean_run() {
    local runner
    runner="$(_resolve_companion "runners/clean.sh")"
    [[ -n "$runner" ]] || _die "runners/clean.sh not found (set \$MESH_HOME or check installation)"
    exec bash "$runner" "$@"
}

mesh_register_command \
    --name clean \
    --summary "Reclaim regenerable dev caches" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_clean_run
