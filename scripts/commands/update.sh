# shellcheck shell=bash

_mesh_update_normalize_topic_spec() {
    local raw="$*"
    raw="${raw//,/ }"
    # shellcheck disable=SC2086
    set -- $raw
    printf '%s' "$*"
}

cmd_update_run() {
    export DEV_BOOTSTRAP_TMUX_AUTO_MAIN=0
    # Resolve this host's alias so the engine's --update pass can read its
    # per-host autoupdate override (config/autoupdate.default.<alias>).
    export MESH_AUTOUPDATE_ALIAS="${MESH_AUTOUPDATE_ALIAS:-$(_mesh_self_alias)}"

    local motor
    motor="$(_resolve_companion "runners/auto-update.sh")"
    [[ -n "$motor" ]] || _die "runners/auto-update.sh not found (set \$MESH_HOME or check installation)"

    if (( $# == 1 )) && [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        exec bash "$motor" --help
    fi

    # Flags forwarded to the motor verbatim. `-o NAME` / `--only NAME` is
    # extracted into $only because we use it both for single-target dispatch
    # and (when empty) for the both-repos fallback below.
    local only=""
    local topics_spec=""
    local full=0
    local interactive=0
    local pass_args=()
    while (( $# > 0 )); do
        case "$1" in
            -o|--only)
                shift
                local val="${1:-}"
                if [[ -z "$val" || "$val" == -* ]]; then
                    _die "update: -o/--only requires a repo name (mesh-workstation | mesh-identity)"
                fi
                case "$val" in
                    workstation) val="mesh-workstation" ;;
                    identity)   val="mesh-identity" ;;
                esac
                only="$val"
                shift
                ;;
            -t|--topics)
                shift
                local val="${1:-}"
                if [[ -z "$val" || "$val" == -* ]]; then
                    _die "update: -t/--topics requires a topic number or name"
                fi
                topics_spec="$topics_spec $val"
                shift
                ;;
            --topics=*)
                local val="${1#*=}"
                [[ -n "$val" ]] || _die "update: --topics requires a topic number or name"
                topics_spec="$topics_spec $val"
                shift
                ;;
            -f|--full)         full=1; pass_args+=("--full");        shift ;;
            -i|--interactive)  interactive=1; pass_args+=("--interactive"); shift ;;
            --*|-*)            pass_args+=("$1");            shift ;;
            *)
                _die "update: unknown arg '$1' (expected -o NAME | -f | -i | -t TOPICS | passthrough flag)"
                ;;
        esac
    done

    if [[ -n "$topics_spec" ]]; then
        (( interactive == 0 )) || _die "update: --topics cannot be combined with -i/--interactive"
        if [[ -n "$only" && "$only" != "mesh-workstation" ]]; then
            _die "update: --topics applies only to mesh-workstation"
        fi
        only="mesh-workstation"
        topics_spec="$(_mesh_update_normalize_topic_spec "$topics_spec")"
        [[ -n "$topics_spec" ]] || _die "update: --topics requires a topic number or name"
        if (( full == 0 )); then
            pass_args+=("--full")
        fi
        export ONLY_TOPICS="$topics_spec"
        export DEV_BOOTSTRAP_REQUIRE_ONLY_TOPICS=1
    fi

    if [[ -n "$only" ]]; then
        exec bash "$motor" --only "$only" "${pass_args[@]+"${pass_args[@]}"}"
    fi

    # No -o/--only - run both sequentially. Preserve the first non-zero rc as
    # the primary failure while still visiting identity after workstation.
    # Bitwise OR can invent a third code (for example 78 | 1 = 79), destroying
    # the causal result that setup/install returned. Bash 3.2 safe expansion.
    local ws_rc=0 id_rc=0
    bash "$motor" --only mesh-workstation "${pass_args[@]+"${pass_args[@]}"}"
    ws_rc=$?
    bash "$motor" --only mesh-identity "${pass_args[@]+"${pass_args[@]}"}"
    id_rc=$?
    (( ws_rc != 0 )) && exit "$ws_rc"
    exit "$id_rc"
}

sub_update() {
    cmd_update_run "$@"
}

mesh_register_command \
    --name update \
    --summary "Pull and apply mesh updates" \
    --group core \
    --origin core \
    --visibility public \
    --fanout allowed \
    --handler cmd_update_run \
    --fanout-validator _mesh_fanout_validate_update
