#!/usr/bin/env bash
# lib/state.sh — persist dev-bootstrap decisions across runs.
#
# State lives in ~/.config/dev-bootstrap/state.env as a shell-sourceable
# KEY="VALUE" file. This format is deliberate — `00-core` runs before any
# topic that might install jq, so state must be readable without external
# tools. Bash 3.2 (Mac default) is the floor.
#
# Single source of truth for things the user once chose and shouldn't be
# asked again on every run — the canonical example is the Homebrew prefix.
# When a user explicitly opts in to a non-canonical prefix
# (e.g. /Volumes/External/homebrew because their internal SSD is small or
# because they prefer dev tooling on a separate volume), that decision
# needs to survive every subsequent `bash install.sh` without re-prompting.
#
# Source from a topic or bootstrap.sh; do not execute directly.
#
# Public API:
#   state_path                          → prints path to state file
#   state_load                          → sources state file if present (sets BREW_PREFIX, ...)
#   state_get KEY                       → prints value, exits 1 if absent
#   state_set KEY VALUE                 → atomic write
#   state_record_brew_prefix PREFIX METHOD
#                                       → write BREW_PREFIX + metadata in one call
#
# Test hook:
#   DEV_BOOTSTRAP_STATE_DIR=...         override state directory (used by tests)

[ -n "${_STATE_LOADED:-}" ] && return 0
_STATE_LOADED=1

state_path() {
    printf '%s/state.env' "${DEV_BOOTSTRAP_STATE_DIR:-$HOME/.config/dev-bootstrap}"
}

# Source the state file if it exists. Idempotent.
# After this call, callers can read previously-persisted values directly:
#   state_load
#   echo "$BREW_PREFIX"     # if previously recorded
state_load() {
    local path
    path="$(state_path)"
    if [[ -f "$path" ]]; then
        # shellcheck source=/dev/null
        source "$path"
    fi
}

# Read a single key. Prints value to stdout; exits 1 if absent or no state file.
# Sources the file in a subshell so bash itself does the unescaping that
# state_set's writer encoded (`\"` → `"`, `\\` → `\`). This keeps the
# shell-sourceable invariant honest: state_get and `source state.env;
# echo $KEY` produce the same value.
state_get() {
    local key="$1" path
    path="$(state_path)"
    [[ -f "$path" ]] || return 1
    grep -qE "^${key}=" "$path" 2>/dev/null || return 1
    (
        # shellcheck source=/dev/null
        source "$path" 2>/dev/null
        eval "printf '%s' \"\${${key}}\""
    )
}

# Atomically write a single key=value pair, preserving any existing entries
# for other keys. Idempotent — same call twice produces the same file.
state_set() {
    local key="$1" value="$2"
    local path dir
    path="$(state_path)"
    dir="$(dirname "$path")"

    mkdir -p "$dir"
    chmod 0700 "$dir" 2>/dev/null || true

    local tmp="${path}.tmp.$$"
    {
        printf '# dev-bootstrap state — auto-generated. Do not edit by hand.\n'
        printf '# Read+written by lib/state.sh. Last updated: %s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if [[ -f "$path" ]]; then
            # Preserve every existing key=value line EXCEPT the one we're updating
            # and our own metadata comments (regenerated above).
            grep -vE "^${key}=" "$path" 2>/dev/null \
                | grep -vE '^#' \
                | grep -vE '^[[:space:]]*$' \
                || true
        fi
        printf '%s="%s"\n' "$key" "$(_state_escape "$value")"
    } > "$tmp"

    mv "$tmp" "$path"
    chmod 0600 "$path" 2>/dev/null || true
}

# Convenience: record a Brew prefix decision with timestamp + method in one
# atomic-feeling call. Method is one of:
#   detected_existing  — found brew on disk; no choice was made
#   env_var            — BREW_CUSTOM_PREFIX was set in the environment
#   prompt             — user picked it interactively from the menu
#   default            — fell back to /opt/homebrew (canonical default)
state_record_brew_prefix() {
    local prefix="$1" method="${2:-default}"
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    state_set BREW_PREFIX "$prefix"
    state_set BREW_PREFIX_DECIDED_AT "$now"
    state_set BREW_PREFIX_DECISION_METHOD "$method"
}

# Internal — escape backslashes and double quotes for embedding in a
# double-quoted shell string. Bash 3.2 compatible (no `${var//pat/repl}`
# nesting tricks).
_state_escape() {
    local s="$1"
    s="${s//\\/\\\\}"   # \ → \\
    s="${s//\"/\\\"}"   # " → \"
    printf '%s' "$s"
}
