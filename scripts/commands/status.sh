# shellcheck shell=bash

cmd_status_run() {
    local lib
    lib="$(_resolve_companion "internal/mesh-status")"
    [[ -n "$lib" ]] || _die "internal/mesh-status not found (set \$MESH_HOME or check installation)"

    local first="${1:-}"
    case "$first" in
        --*|-*|"")
            exec "$lib" "$@"
            ;;
        *)
            local alias_arg="$1"
            shift
            exec "$lib" --detail "$alias_arg" "$@"
            ;;
    esac
}

mesh_register_command \
    --name status \
    --summary "Show cross-mesh status" \
    --group core \
    --origin core \
    --visibility public \
    --fanout allowed \
    --handler cmd_status_run \
    --fanout-validator _mesh_fanout_validate_any
