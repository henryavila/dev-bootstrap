# shellcheck shell=bash

cmd_topic_help() {
    cat <<'EOF'
Usage:
  mesh topic list
  mesh topic <NN|NN-name> [...]

Examples:
  mesh topic list
  mesh topic 20 30
  mesh topic 20-terminal-ux 30-shell
EOF
}

cmd_topic_run() {
    case "${1:-}" in
        -h|--help|"")
            cmd_topic_help
            return 0
            ;;
        list)
            shift
            (( $# == 0 )) || _die "topic list: unexpected arg '$1'"
            local repo
            repo="$(_resolve_workstation_repo)" || \
                _die "mesh-workstation repo not found (set MESH_WORKSTATION_DIR)"
            exec bash "$repo/setup.sh" --list-bundles
            ;;
    esac

    local topics
    topics="$(_normalize_topic_spec "$@")"
    [[ -n "$topics" ]] || _die "topic: missing topic number"
    sub_update --topics "$topics"
}

mesh_register_command \
    --name topic \
    --summary "List or apply mesh topics" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_topic_run
