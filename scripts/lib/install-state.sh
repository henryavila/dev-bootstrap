#!/usr/bin/env bash
# scripts/lib/install-state.sh — per-item installation state markers.
#
# Each successful install writes a marker file:
#   $MESH_INSTALL_STATE_DIR/<topic>__<name>.env  (default: ~/.local/state/mesh/installed/)
#
# Format is shell-sourceable key=value so it can be read without jq:
#   MESH_ITEM_TOPIC=remote-access
#   MESH_ITEM_NAME=remote-login-mac
#   MESH_ITEM_TYPE=custom
#   MESH_ITEM_SPEC="./enable-remote-login.sh"
#   MESH_ITEM_INSTALLED_AT=2026-05-28T14:22:09Z
#
# The marker is the single source of truth for "did mesh install this?".
# It complements (does not replace) driver-level _check probes:
#   - marker present + driver check ok → steady
#   - marker present + driver check fails → drift-out (user removed manually)
#   - marker absent  + driver check ok → drift-in (foreign install)
#   - marker absent  + driver check fails → not installed
#
# For types where no reliable driver check exists (npx, future opaque
# installers), the marker IS the detection signal.
#
# Bash 3.2 floor (engine runs under /bin/bash on macOS); no jq/yq required.
#
# Public API:
#   install_state_dir                                → echoes marker directory
#   install_state_path TOPIC NAME                    → echoes marker file path
#   install_state_record TOPIC NAME TYPE SPEC        → write marker (atomic)
#   install_state_remove TOPIC NAME                  → rm -f marker
#   install_state_has TOPIC NAME                     → exit 0 if marker exists
#   install_state_get TOPIC NAME KEY                 → echo recorded value
#   install_state_list                               → echo "topic name" per line
#
# Test hook:
#   MESH_INSTALL_STATE_DIR=...   override marker directory

[ -n "${_INSTALL_STATE_LOADED:-}" ] && return 0
_INSTALL_STATE_LOADED=1

install_state_dir() {
    printf '%s' "${MESH_INSTALL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/mesh/installed}"
}

# Sanitize topic/name to a filesystem-safe slot. We refuse anything that
# isn't [A-Za-z0-9._-] because the slot is used directly as the filename.
_install_state_slot() {
    local topic="$1" name="$2"
    case "$topic" in
        ''|*/*|*..*) return 1 ;;
    esac
    case "$name" in
        ''|*/*|*..*) return 1 ;;
    esac
    printf '%s__%s' "$topic" "$name"
}

install_state_path() {
    local topic="$1" name="$2" slot
    slot="$(_install_state_slot "$topic" "$name")" || return 1
    printf '%s/%s.env' "$(install_state_dir)" "$slot"
}

# Escape a value for shell-sourceable double-quoted output: backslash,
# double-quote, dollar, and backtick are the only metacharacters that
# break parsing inside "...".
_install_state_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//\$/\\\$}"
    s="${s//\`/\\\`}"
    printf '%s' "$s"
}

install_state_record() {
    local topic="$1" name="$2" type="${3:-}" spec="${4:-}"
    local path
    path="$(install_state_path "$topic" "$name")" || return 1
    local dir
    dir="$(dirname "$path")"
    mkdir -p "$dir" 2>/dev/null || return 1
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')"
    local tmp="${path}.tmp.$$"
    {
        printf 'MESH_ITEM_TOPIC="%s"\n'        "$(_install_state_escape "$topic")"
        printf 'MESH_ITEM_NAME="%s"\n'         "$(_install_state_escape "$name")"
        printf 'MESH_ITEM_TYPE="%s"\n'         "$(_install_state_escape "$type")"
        printf 'MESH_ITEM_SPEC="%s"\n'         "$(_install_state_escape "$spec")"
        printf 'MESH_ITEM_INSTALLED_AT="%s"\n' "$ts"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
    chmod 0644 "$path" 2>/dev/null || true
}

install_state_remove() {
    local topic="$1" name="$2" path
    path="$(install_state_path "$topic" "$name")" || return 1
    [[ -f "$path" ]] || return 0
    rm -f "$path"
}

install_state_has() {
    local topic="$1" name="$2" path
    path="$(install_state_path "$topic" "$name")" || return 1
    [[ -f "$path" ]]
}

install_state_get() {
    local topic="$1" name="$2" key="$3" path
    path="$(install_state_path "$topic" "$name")" || return 1
    [[ -f "$path" ]] || return 1
    (
        # shellcheck source=/dev/null
        source "$path" 2>/dev/null || exit 1
        eval "printf '%s' \"\${${key}:-}\""
    )
}

install_state_list() {
    local dir
    dir="$(install_state_dir)"
    [[ -d "$dir" ]] || return 0
    local f base topic name
    for f in "$dir"/*.env; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f" .env)"
        topic="${base%%__*}"
        name="${base#*__}"
        [[ "$topic" != "$base" ]] || continue
        printf '%s %s\n' "$topic" "$name"
    done
}
