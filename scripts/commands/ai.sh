# shellcheck shell=bash

cmd_ai_run() {
    local runner
    runner="$(_resolve_companion "runners/ai.sh")"
    [[ -n "$runner" ]] || _die "runners/ai.sh not found (set \$MESH_HOME or check installation)"
    exec bash "$runner" "$@"
}

sub_ai() {
    cmd_ai_run "$@"
}

mesh_register_command \
    --name ai \
    --summary "Open an AI agent in the right repo" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_ai_run
