# shellcheck shell=bash
# scripts/lib/mesh-command.sh — Bash-native command registry.
#
# Source-only: defines the registry API and initializes in-memory arrays. Command
# modules may source this file, define cmd_* functions, and call
# mesh_register_command without executing command behavior.

if [ "${_MESH_COMMAND_REGISTRY_LOADED:-0}" != "1" ]; then
    _MESH_COMMAND_REGISTRY_LOADED=1
    _MESH_COMMAND_NAMES=()
    _MESH_COMMAND_SUMMARIES=()
    _MESH_COMMAND_GROUPS=()
    _MESH_COMMAND_ORIGINS=()
    _MESH_COMMAND_VISIBILITIES=()
    _MESH_COMMAND_FANOUTS=()
    _MESH_COMMAND_HANDLERS=()
    _MESH_COMMAND_FANOUT_VALIDATORS=()
    _MESH_COMMAND_FANOUT_ENV_PROVIDERS=()
fi

mesh_command_reset_registry() {
    _MESH_COMMAND_NAMES=()
    _MESH_COMMAND_SUMMARIES=()
    _MESH_COMMAND_GROUPS=()
    _MESH_COMMAND_ORIGINS=()
    _MESH_COMMAND_VISIBILITIES=()
    _MESH_COMMAND_FANOUTS=()
    _MESH_COMMAND_HANDLERS=()
    _MESH_COMMAND_FANOUT_VALIDATORS=()
    _MESH_COMMAND_FANOUT_ENV_PROVIDERS=()
}

_mesh_command_error() {
    _MESH_COMMAND_REGISTRY_ERROR=1
    printf 'mesh command registry: %s\n' "$*" >&2
}

_mesh_command_has_tab_or_newline() {
    case "$1" in
        *$'\t'*|*$'\n'*) return 0 ;;
        *) return 1 ;;
    esac
}

_mesh_command_valid_name() {
    [[ "$1" =~ ^([a-z][a-z0-9-]*|__[a-z][a-z0-9-]*)$ ]]
}

_mesh_command_valid_group() {
    [[ "$1" =~ ^[a-z][a-z0-9-]*$ ]]
}

_mesh_command_valid_function_name() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

_mesh_command_validate_text_field() {
    local label="$1" value="$2"
    if [ -z "$value" ]; then
        _mesh_command_error "missing required field: $label"
        return 1
    fi
    if _mesh_command_has_tab_or_newline "$value"; then
        _mesh_command_error "$label contains a tab or newline"
        return 1
    fi
    return 0
}

_mesh_command_validate_function_ref() {
    local label="$1" value="$2" required="$3"
    if [ -z "$value" ]; then
        if [ "$required" = "1" ]; then
            _mesh_command_error "missing required field: $label"
            return 1
        fi
        return 0
    fi
    if _mesh_command_has_tab_or_newline "$value"; then
        _mesh_command_error "$label contains a tab or newline"
        return 1
    fi
    if ! _mesh_command_valid_function_name "$value"; then
        _mesh_command_error "$label is not a valid function name: $value"
        return 1
    fi
    if ! declare -F "$value" >/dev/null 2>&1; then
        _mesh_command_error "$label function is not defined: $value"
        return 1
    fi
    return 0
}

mesh_command_index() {
    local name="$1" i
    i=0
    while [ "$i" -lt "${#_MESH_COMMAND_NAMES[@]}" ]; do
        if [ "${_MESH_COMMAND_NAMES[$i]}" = "$name" ]; then
            printf '%s\n' "$i"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

mesh_command_registered() {
    mesh_command_index "$1" >/dev/null 2>&1
}

mesh_command_names() {
    local i
    i=0
    while [ "$i" -lt "${#_MESH_COMMAND_NAMES[@]}" ]; do
        printf '%s\n' "${_MESH_COMMAND_NAMES[$i]}"
        i=$((i + 1))
    done
}

mesh_command_get() {
    local name="$1" field="$2" idx
    idx="$(mesh_command_index "$name")" || return 1
    case "$field" in
        name) printf '%s\n' "${_MESH_COMMAND_NAMES[$idx]}" ;;
        summary) printf '%s\n' "${_MESH_COMMAND_SUMMARIES[$idx]}" ;;
        group) printf '%s\n' "${_MESH_COMMAND_GROUPS[$idx]}" ;;
        origin) printf '%s\n' "${_MESH_COMMAND_ORIGINS[$idx]}" ;;
        visibility) printf '%s\n' "${_MESH_COMMAND_VISIBILITIES[$idx]}" ;;
        fanout) printf '%s\n' "${_MESH_COMMAND_FANOUTS[$idx]}" ;;
        handler) printf '%s\n' "${_MESH_COMMAND_HANDLERS[$idx]}" ;;
        fanout_validator) printf '%s\n' "${_MESH_COMMAND_FANOUT_VALIDATORS[$idx]}" ;;
        fanout_env_provider) printf '%s\n' "${_MESH_COMMAND_FANOUT_ENV_PROVIDERS[$idx]}" ;;
        *)
            _mesh_command_error "unknown field: $field"
            return 1
            ;;
    esac
}

_mesh_command_visibility_in_scope() {
    local visibility="$1" scope="$2"
    case "$scope" in
        public) [ "$visibility" = public ] ;;
        all) [ "$visibility" = public ] || [ "$visibility" = hidden ] ;;
        internal) return 0 ;;
        *) return 1 ;;
    esac
}

mesh_command_emit_tsv() {
    local scope="public" i visibility
    case "${1:-}" in
        "") ;;
        --public) scope="public" ;;
        --all) scope="all" ;;
        --internal) scope="internal" ;;
        *)
            _mesh_command_error "unknown mesh_command_emit_tsv option: $1"
            return 1
            ;;
    esac

    i=0
    while [ "$i" -lt "${#_MESH_COMMAND_NAMES[@]}" ]; do
        visibility="${_MESH_COMMAND_VISIBILITIES[$i]}"
        if _mesh_command_visibility_in_scope "$visibility" "$scope"; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "${_MESH_COMMAND_NAMES[$i]}" \
                "${_MESH_COMMAND_SUMMARIES[$i]}" \
                "${_MESH_COMMAND_GROUPS[$i]}" \
                "${_MESH_COMMAND_ORIGINS[$i]}" \
                "$visibility" \
                "${_MESH_COMMAND_FANOUTS[$i]}"
        fi
        i=$((i + 1))
    done | LC_ALL=C sort -t $'\t' -k3,3 -k1,1
}

mesh_register_command() {
    local name="" summary="" group="" origin="" visibility="" fanout=""
    local handler="" fanout_validator="" fanout_env_provider=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --name)
                [ "$#" -ge 2 ] || { _mesh_command_error "missing value for --name"; return 2; }
                name="$2"; shift 2
                ;;
            --summary)
                [ "$#" -ge 2 ] || { _mesh_command_error "missing value for --summary"; return 2; }
                summary="$2"; shift 2
                ;;
            --group)
                [ "$#" -ge 2 ] || { _mesh_command_error "missing value for --group"; return 2; }
                group="$2"; shift 2
                ;;
            --origin)
                [ "$#" -ge 2 ] || { _mesh_command_error "missing value for --origin"; return 2; }
                origin="$2"; shift 2
                ;;
            --visibility)
                [ "$#" -ge 2 ] || { _mesh_command_error "missing value for --visibility"; return 2; }
                visibility="$2"; shift 2
                ;;
            --fanout)
                [ "$#" -ge 2 ] || { _mesh_command_error "missing value for --fanout"; return 2; }
                fanout="$2"; shift 2
                ;;
            --handler)
                [ "$#" -ge 2 ] || { _mesh_command_error "missing value for --handler"; return 2; }
                handler="$2"; shift 2
                ;;
            --fanout-validator)
                [ "$#" -ge 2 ] || { _mesh_command_error "missing value for --fanout-validator"; return 2; }
                fanout_validator="$2"; shift 2
                ;;
            --fanout-env|--fanout-env-provider)
                [ "$#" -ge 2 ] || { _mesh_command_error "missing value for $1"; return 2; }
                fanout_env_provider="$2"; shift 2
                ;;
            *)
                _mesh_command_error "unknown mesh_register_command option: $1"
                return 2
                ;;
        esac
    done

    _mesh_command_validate_text_field "name" "$name" || return 1
    if ! _mesh_command_valid_name "$name"; then
        _mesh_command_error "name is not a valid command name: $name"
        return 1
    fi
    if mesh_command_registered "$name"; then
        _mesh_command_error "duplicate command: $name"
        return 1
    fi

    _mesh_command_validate_text_field "summary" "$summary" || return 1
    _mesh_command_validate_text_field "group" "$group" || return 1
    if ! _mesh_command_valid_group "$group"; then
        _mesh_command_error "group is not a valid group name: $group"
        return 1
    fi

    _mesh_command_validate_text_field "origin" "$origin" || return 1
    case "$origin" in
        core|legacy|identity) ;;
        *) _mesh_command_error "origin must be core, legacy, or identity: $origin"; return 1 ;;
    esac

    _mesh_command_validate_text_field "visibility" "$visibility" || return 1
    case "$visibility" in
        public|hidden|internal) ;;
        *) _mesh_command_error "visibility must be public, hidden, or internal: $visibility"; return 1 ;;
    esac

    _mesh_command_validate_text_field "fanout" "$fanout" || return 1
    case "$fanout" in
        allowed|none) ;;
        *) _mesh_command_error "fanout must be allowed or none: $fanout"; return 1 ;;
    esac

    _mesh_command_validate_function_ref "handler" "$handler" 1 || return 1
    _mesh_command_validate_function_ref "fanout_validator" "$fanout_validator" 0 || return 1
    _mesh_command_validate_function_ref "fanout_env_provider" "$fanout_env_provider" 0 || return 1

    _MESH_COMMAND_NAMES+=("$name")
    _MESH_COMMAND_SUMMARIES+=("$summary")
    _MESH_COMMAND_GROUPS+=("$group")
    _MESH_COMMAND_ORIGINS+=("$origin")
    _MESH_COMMAND_VISIBILITIES+=("$visibility")
    _MESH_COMMAND_FANOUTS+=("$fanout")
    _MESH_COMMAND_HANDLERS+=("$handler")
    _MESH_COMMAND_FANOUT_VALIDATORS+=("$fanout_validator")
    _MESH_COMMAND_FANOUT_ENV_PROVIDERS+=("$fanout_env_provider")
}
