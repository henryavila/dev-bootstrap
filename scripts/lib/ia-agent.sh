# shellcheck shell=bash
# scripts/lib/ia-agent.sh — agent command resolution + per-project memory for `mesh ia`.
# Source-only (no top-level execution).
#
# The agent NAME and the personal launch FLAGS are policy, not mechanism, so
# they come from the environment (mesh-identity sets them; a fork inherits a
# safe bare default):
#   MESH_IA_AGENT          default agent name (identity → 'claude'); fallback 'claude'
#   MESH_IA_FLAGS_<AGENT>  extra flags per agent, name uppercased and non-alnum→'_'
#                          (identity → MESH_IA_FLAGS_CLAUDE='--dangerously-skip-permissions')
#
# The last agent used for a project is remembered in a tiny state file, so
# `mesh ia <proj>` reopens with the same agent and never asks; `--agent X`
# overrides for this run AND updates the memory.

# Path to the per-project agent memory (KEY=value lines, project=agent).
ia_agent_state_file() {
    printf '%s/mesh/ia-agents.env' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# Print the remembered agent for a project name, or nothing.
ia_agent_get() {
    local proj="$1" f key val
    f="$(ia_agent_state_file)"
    [[ -r "$f" ]] || return 0
    while IFS='=' read -r key val || [[ -n "$key" ]]; do
        [[ "$key" == "$proj" ]] && { printf '%s' "$val"; return 0; }
    done < "$f"
}

# Remember the agent for a project (idempotent upsert; never fatal).
ia_agent_set() {
    local proj="$1" agent="$2" f tmp
    f="$(ia_agent_state_file)"
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
    tmp="$(mktemp "${f}.XXXXXX" 2>/dev/null)" || return 0
    if [[ -r "$f" ]]; then
        awk -v p="$proj" -F= '$1 != p' "$f" > "$tmp" 2>/dev/null || true
    fi
    printf '%s=%s\n' "$proj" "$agent" >> "$tmp"
    mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
}

# Resolve the default agent name for a project: explicit override > remembered
# for this project > MESH_IA_AGENT > 'claude'.
#   $1 project name   $2 override (may be empty)
ia_agent_resolve() {
    local proj="$1" override="${2:-}" remembered
    if [[ -n "$override" ]]; then
        printf '%s' "$override"
        return 0
    fi
    remembered="$(ia_agent_get "$proj")"
    if [[ -n "$remembered" ]]; then
        printf '%s' "$remembered"
        return 0
    fi
    printf '%s' "${MESH_IA_AGENT:-claude}"
}

# Build the full launch command for an agent name: "<agent> <flags>" (flags from
# MESH_IA_FLAGS_<AGENT>, empty when unset → a bare `claude`/`codex` for forks).
ia_agent_cmd() {
    local agent="$1" var flags
    var="MESH_IA_FLAGS_$(printf '%s' "$agent" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
    var="${var%_}"
    flags="${!var:-}"
    if [[ -n "$flags" ]]; then
        printf '%s %s' "$agent" "$flags"
    else
        printf '%s' "$agent"
    fi
}
