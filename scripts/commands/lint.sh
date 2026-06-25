# shellcheck shell=bash

cmd_lint_run() {
    local lib
    lib="$(_resolve_companion "lib/lint.sh")"
    [[ -n "$lib" ]] || _die "lib/lint.sh not found (set \$MESH_HOME or check installation)"
    exec bash "$lib" "$@"
}

mesh_register_command \
    --name lint \
    --summary "Run repo invariant lints" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_lint_run
