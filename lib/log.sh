#!/usr/bin/env bash
# lib/log.sh — output helpers. Source this file; do not execute.
# Respects NO_COLOR env var and non-TTY stdout.

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    _C_RED=$'\033[31m'
    _C_GRN=$'\033[32m'
    _C_YEL=$'\033[33m'
    _C_BLU=$'\033[34m'
    _C_BLD=$'\033[1m'
    _C_RST=$'\033[0m'
else
    _C_RED=""; _C_GRN=""; _C_YEL=""; _C_BLU=""; _C_BLD=""; _C_RST=""
fi

info()   { printf '%s→%s %s\n' "$_C_BLU" "$_C_RST" "$*"; }
ok()     { printf '%s✓%s %s\n' "$_C_GRN" "$_C_RST" "$*"; }
warn()   { printf '%s!%s %s\n' "$_C_YEL" "$_C_RST" "$*" >&2; }
fail()   { printf '%s✗%s %s\n' "$_C_RED" "$_C_RST" "$*" >&2; }
banner() { printf '\n%s== %s ==%s\n' "$_C_BLD" "$*" "$_C_RST"; }

# followup — record a post-bootstrap action that needs human attention.
# Writes one line per entry to $BOOTSTRAP_FOLLOWUP_FILE (bootstrap.sh
# creates this file at start and prints a consolidated summary at the
# end). Each entry has a severity that shapes how the summary renders.
#
# Severities:
#   critical  — feature is broken until resolved (e.g. Windows CA skip)
#   manual    — routine manual step (atuin login, ngrok token, chsh, …)
#   info      — optional tweak worth mentioning
#
# Usage:
#   followup critical "Windows CA import skipped — HTTPS localhost
#                      won't work in Chrome/Edge. Diagnose with:
#                      bash ~/dev-bootstrap/topics/60-web-stack/scripts/diagnose-wsl-interop.sh"
#
# The message can be multi-line (actual newlines); the summary will
# indent continuation lines for readability.
followup() {
    local severity="$1"
    shift
    local msg="$*"

    # Also echo inline so the topic still prints the warning as it
    # happens (keeps existing UX). Severity controls the prefix char.
    case "$severity" in
        critical) fail "$msg" ;;
        manual)   warn "$msg" ;;
        info)     info "$msg" ;;
        *)        warn "$msg" ;;
    esac

    # Persist to the follow-up file if bootstrap.sh set one up. Topics
    # invoked directly (ONLY_TOPICS) or outside the runner get the
    # inline output but no consolidated summary — that's fine.
    if [[ -n "${BOOTSTRAP_FOLLOWUP_FILE:-}" ]]; then
        # Use a unit separator + record separator so multi-line messages
        # round-trip cleanly through a single file.
        printf '%s\x1f%s\x1e' "$severity" "$msg" >> "$BOOTSTRAP_FOLLOWUP_FILE" 2>/dev/null || true
    fi
}

# render_followup_summary — read $BOOTSTRAP_FOLLOWUP_FILE and print
# a grouped, human-readable summary. Called by bootstrap.sh right
# before exit so the user sees all pending actions in one place,
# not scattered across topic output.
render_followup_summary() {
    local f="${BOOTSTRAP_FOLLOWUP_FILE:-}"
    [[ -z "$f" ]] && return 0
    [[ ! -s "$f" ]] && return 0

    # Parse records separated by \x1e (record sep). Each record is
    # severity\x1fmsg. Split into arrays by severity.
    local -a crit_msgs manual_msgs info_msgs
    crit_msgs=() manual_msgs=() info_msgs=()

    local IFS=$'\x1e'
    local record sev msg
    while IFS= read -r -d $'\x1e' record; do
        [[ -z "$record" ]] && continue
        sev="${record%%$'\x1f'*}"
        msg="${record#*$'\x1f'}"
        case "$sev" in
            critical) crit_msgs+=("$msg") ;;
            manual)   manual_msgs+=("$msg") ;;
            info)     info_msgs+=("$msg") ;;
        esac
    done < "$f"

    # Nothing to show? quick exit.
    local total=$(( ${#crit_msgs[@]} + ${#manual_msgs[@]} + ${#info_msgs[@]} ))
    [[ "$total" -eq 0 ]] && return 0

    banner "follow-up — manual steps that finish the setup"

    if [[ "${#crit_msgs[@]}" -gt 0 ]]; then
        printf '\n%sCritical%s — these BLOCK functionality until resolved:\n' \
            "$_C_RED$_C_BLD" "$_C_RST"
        local i
        for ((i=0; i<${#crit_msgs[@]}; i++)); do
            _render_followup_item "$_C_RED✗$_C_RST" "${crit_msgs[$i]}"
        done
    fi

    if [[ "${#manual_msgs[@]}" -gt 0 ]]; then
        printf '\n%sManual config%s — non-blocking, but things stay inert until done:\n' \
            "$_C_YEL$_C_BLD" "$_C_RST"
        for ((i=0; i<${#manual_msgs[@]}; i++)); do
            _render_followup_item "$_C_YEL!$_C_RST" "${manual_msgs[$i]}"
        done
    fi

    if [[ "${#info_msgs[@]}" -gt 0 ]]; then
        printf '\n%sOptional / info%s:\n' "$_C_BLU$_C_BLD" "$_C_RST"
        for ((i=0; i<${#info_msgs[@]}; i++)); do
            _render_followup_item "$_C_BLU→$_C_RST" "${info_msgs[$i]}"
        done
    fi
    echo
}

# Private — renders a single follow-up entry with hanging indent so
# multi-line messages read cleanly.
_render_followup_item() {
    local prefix="$1" msg="$2"
    local first=1 line
    while IFS= read -r line; do
        if [[ "$first" -eq 1 ]]; then
            printf '  %s %s\n' "$prefix" "$line"
            first=0
        else
            printf '    %s\n' "$line"
        fi
    done <<< "$msg"
}
