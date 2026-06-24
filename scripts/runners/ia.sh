#!/usr/bin/env bash
# scripts/runners/ia.sh — `mesh ia` / `mesh ai`: open an AI agent in the right repo via herdr.
#
# herdr (the agent multiplexer) only knows already-OPEN workspaces and has no
# fuzzy discovery of the repos on disk across roots. This verb fills that gap:
# it discovers your repos (multi-root), then hands the chosen project to herdr —
# focus its workspace if already open, else create one at its dir and launch the
# agent in it.
#
# Usage:
#   mesh ia [term]            Open the project matching <term>; single match opens
#                             directly, multiple → picker, none → error.
#   mesh ia                   No term → searchable picker (open workspaces + repos).
#                             Picker keys: Enter = focus/open · Ctrl-N = open a NEW
#                             agent in the highlighted repo (fresh tab if open).
#   mesh ia <term> --agent X  Use agent X (claude|codex|gemini); remembered per project.
#   mesh ia --list            Print the discovered catalogue and exit (no launch).
# Flags: --agent <name>, --list, -h/--help.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1091
. "$REPO/scripts/lib/log.sh"
# shellcheck disable=SC1091
. "$REPO/scripts/lib/ia-discover.sh"
# shellcheck disable=SC1091
. "$REPO/scripts/lib/ia-herdr.sh"
# shellcheck disable=SC1091
. "$REPO/scripts/lib/ia-agent.sh"
# Honor per-host config (CODE_DIR, optional IA_ROOTS) so discovery roots match
# what the interactive shell uses.
if [[ -r "$HOME/.config/mesh/config.env" ]]; then
    # shellcheck disable=SC1091
    . "$HOME/.config/mesh/config.env"
fi

AGENT_OVERRIDE=""; LIST=0; CANDIDATES=0; TERM_ARG=""
while (( $# > 0 )); do
    case "$1" in
        --agent)      shift; AGENT_OVERRIDE="${1:-}" ;;
        --agent=*)    AGENT_OVERRIDE="${1#*=}" ;;
        --list)       LIST=1 ;;
        --candidates) CANDIDATES=1 ;;   # debug: dump the merged candidate set
        -h|--help)    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --)         shift; [[ $# -gt 0 ]] && TERM_ARG="$1" ;;
        -*)         log_error "ia: unknown flag '$1' (try --agent <name> --list --help)"; exit 2 ;;
        *)          TERM_ARG="$1" ;;
    esac
    shift
done

if (( LIST )); then
    ia_match "$TERM_ARG"
    exit 0
fi

# Open a disk repo (name+path) with the resolved agent; remember --agent choices.
_ia_open_repo() {
    local name="$1" path="$2" agent agent_cmd
    agent="$(ia_agent_resolve "$name" "$AGENT_OVERRIDE")"
    [[ -n "$AGENT_OVERRIDE" ]] && ia_agent_set "$name" "$agent"
    agent_cmd="$(ia_agent_cmd "$agent")"
    ia_herdr_open "$name" "$path" "$agent_cmd"
}

# Build the MERGED candidate set, one `label<TAB>path<TAB>wsid<TAB>status<TAB>tabid`
# row:
#   • an open herdr workspace whose label matches a discovered repo → ONE row
#     carrying the repo path + the workspace id + status (no duplicate);
#   • an open workspace with no matching repo (e.g. a branch-named workspace in a
#     git worktree) → its pane cwd as the path, so you still see WHICH project;
#   • for a workspace with >1 tab, ALSO one `<ws> › <tab>` row per tab carrying
#     its tab_id — so you can search a task name and jump straight to that tab;
#   • a discovered repo with no open workspace → path only, empty wsid.
# tabid set ⇒ focus that tab; else wsid set ⇒ focus workspace; else ⇒ create.
_ia_candidates() {
    local repos open_ws label wsid status path name tabs ntabs tid tlabel tstatus
    repos="$(ia_discover)"
    open_ws=""
    ia_herdr_ready 2>/dev/null && open_ws="$(ia_herdr_workspaces)"

    # Open workspaces (deduped against disk by label), each optionally expanded
    # into its tabs.
    while IFS=$'\t' read -r label wsid status; do
        [[ -n "$label" ]] || continue
        path="$(printf '%s\n' "$repos" | awk -F'\t' -v n="$label" '$1 == n { print $2; exit }')"
        [[ -n "$path" ]] || path="$(ia_herdr_workspace_cwd "$wsid")"
        printf '%s\t%s\t%s\t%s\t\n' "$label" "$path" "$wsid" "$status"

        tabs="$(ia_herdr_tabs "$wsid")"
        ntabs="$(printf '%s' "$tabs" | awk 'NF{n++} END{print n+0}')"
        if (( ntabs > 1 )); then
            while IFS=$'\t' read -r tid tlabel tstatus; do
                [[ -n "$tid" ]] || continue
                printf '%s › %s\t%s\t%s\t%s\t%s\n' "$label" "$tlabel" "$path" "$wsid" "$tstatus" "$tid"
            done <<<"$tabs"
        fi
    done <<<"$open_ws"

    # Discovered repos with no open workspace of the same name.
    while IFS=$'\t' read -r name path; do
        [[ -n "$name" ]] || continue
        printf '%s\n' "$open_ws" | awk -F'\t' -v n="$name" '$1 == n { found = 1 } END { exit !found }' \
            || printf '%s\t%s\t\t\t\n' "$name" "$path"
    done <<<"$repos"
}

# Filter merged rows by a case-insensitive substring on the label (col 1). Empty
# term passes everything through.
_ia_filter() {
    local term="${1:-}" lc label
    if [[ -z "$term" ]]; then cat; return 0; fi
    lc="$(printf '%s' "$term" | tr '[:upper:]' '[:lower:]')"
    while IFS= read -r line; do
        label="${line%%$'\t'*}"
        case "$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')" in
            *"$lc"*) printf '%s\n' "$line" ;;
        esac
    done
}

# Open a NEW agent for a chosen row: a fresh tab inside the project's workspace
# when one is open, else a freshly-created workspace (same as opening a closed
# repo). Honors --agent + the remember-last memory, exactly like _ia_open_repo.
_ia_open_new() {
    local name="$1" path="$2" wsid="$3" agent agent_cmd
    agent="$(ia_agent_resolve "$name" "$AGENT_OVERRIDE")"
    [[ -n "$AGENT_OVERRIDE" ]] && ia_agent_set "$name" "$agent"
    agent_cmd="$(ia_agent_cmd "$agent")"
    if [[ -n "$wsid" ]]; then
        ia_herdr_new_tab "$wsid" "$path" "$name" "$agent_cmd"
    else
        ia_herdr_open "$name" "$path" "$agent_cmd"
    fi
}

# Route a chosen `action<TAB>label<TAB>path<TAB>wsid<TAB>status<TAB>tabid` line.
# action ∈ {open,new}:
#   open → focus the exact tab if it carries one, else focus the workspace,
#          else create+launch (a closed repo);
#   new  → open ANOTHER agent in the project (a fresh tab in its open workspace,
#          else a freshly-created workspace) — Enter focuses, Ctrl-N opens new.
# Project name = the workspace label (a tab row's `<ws> › <tab>` collapses to
# `<ws>`) so agent memory + the new tab's label track the project, not the tab.
_ia_route() {
    local action label path wsid _status tabid name
    IFS=$'\t' read -r action label path wsid _status tabid <<<"$1"
    name="${label%% › *}"

    if [[ "$action" == new ]]; then
        _ia_open_new "$name" "$path" "$wsid"
        return $?
    fi

    if [[ -n "$tabid" ]]; then
        log_info "ia: focusing tab '$label'"
        ia_herdr_focus_tab "$wsid" "$tabid"
    elif [[ -n "$wsid" ]]; then
        log_info "ia: focusing open workspace '$label'"
        herdr workspace focus "$wsid" >/dev/null
    else
        _ia_open_repo "$label" "$path"
    fi
}

# Blink picker (preferred): feed candidates, read the chosen line back. Exit
# codes mirror ia-pick-main so the caller can tell cancel from unavailable:
#   0   → chosen line printed
#   130 → user pressed Esc (cancel): open nothing, do NOT fall back
#   1   → menu app/runtime unavailable: caller may fall back to the bash picker
_ia_pick_blink() {
    local menu="$REPO/scripts/menu/index.js" cand="$1" out rc
    [[ "${MESH_IA_PICKER:-}" == "bash" ]] && return 1
    command -v node >/dev/null 2>&1 || return 1
    [[ -f "$menu" ]] || return 1
    out="$(mktemp -t mesh-ia-pick.XXXXXX)" || return 1
    node "$menu" ia-pick --in "$cand" --out "$out" </dev/tty >/dev/tty 2>/dev/null
    rc=$?
    if (( rc == 0 )); then
        cat "$out"; rm -f "$out"; return 0
    fi
    rm -f "$out"
    (( rc == 130 )) && return 130   # Esc → cancel, never fall through to bash
    return 1                        # anything else → blink unavailable
}

# Bash fallback picker: a plain numbered chooser on the tty (used when blink is
# unavailable, or MESH_IA_PICKER=bash). Prints the chosen raw line.
_ia_pick_bash() {
    local cand="$1" n=0 sel line label path wsid status tabid
    local -a lines=()
    while IFS= read -r line; do [[ -n "$line" ]] && lines+=("$line"); done < "$cand"
    (( ${#lines[@]} > 0 )) || { log_error "ia: nothing to open"; return 1; }
    for line in "${lines[@]}"; do
        n=$((n + 1))
        IFS=$'\t' read -r label path wsid status tabid <<<"$line"
        if [[ -n "$wsid" ]]; then
            printf '  %2d) %-38s herdr · %-7s %s\n' "$n" "$label" "${status:-?}" "$path" >&2
        else
            printf '  %2d) %-38s %s\n' "$n" "$label" "$path" >&2
        fi
    done
    printf "ia> pick a number ('n'<num> = new agent, q = cancel): " >&2
    IFS= read -r sel </dev/tty || return 1
    [[ "$sel" == q || -z "$sel" ]] && return 1
    local act=open idx
    if [[ "$sel" =~ ^n([0-9]+)$ ]]; then
        act=new; idx="${BASH_REMATCH[1]}"
    elif [[ "$sel" =~ ^[0-9]+$ ]]; then
        idx="$sel"
    else
        log_error "ia: invalid choice"; return 1
    fi
    (( idx >= 1 && idx <= ${#lines[@]} )) || { log_error "ia: invalid choice"; return 1; }
    printf '%s\t%s' "$act" "${lines[$((idx - 1))]}"
}

# Build the merged set once, then filter by the (optional) term.
CAND_FILE="$(mktemp -t mesh-ia-cand.XXXXXX)" || exit 1
FILT_FILE="$(mktemp -t mesh-ia-filt.XXXXXX)" || exit 1
trap 'rm -f "${CAND_FILE:-}" "${FILT_FILE:-}"' EXIT
_ia_candidates > "$CAND_FILE"

if (( CANDIDATES )); then
    cat "$CAND_FILE"
    exit 0
fi

_ia_filter "$TERM_ARG" < "$CAND_FILE" > "$FILT_FILE"
N_FILTERED="$(grep -c . "$FILT_FILE" 2>/dev/null || true)"
N_FILTERED="${N_FILTERED:-0}"

# A term that matches nothing is a hard miss.
if [[ -n "$TERM_ARG" ]] && (( N_FILTERED == 0 )); then
    log_error "ia: no project or workspace matches '$TERM_ARG' (try \`mesh ia --list\`)"
    exit 1
fi
# Nothing to open at all (no repos under IA_ROOTS, no open workspaces).
if (( N_FILTERED == 0 )); then
    log_error "ia: nothing to open — no open herdr workspaces and no repos under IA_ROOTS"
    log_info  "ia: roots searched: $(ia_roots | tr '\n' ' ')"
    exit 1
fi

# Fast path: an explicit term that resolves to exactly one row opens directly
# (always the "open" action — focus-or-create the single match).
if [[ -n "$TERM_ARG" ]] && (( N_FILTERED == 1 )); then
    _ia_route "open"$'\t'"$(cat "$FILT_FILE")"
    exit $?
fi

# Otherwise (no term, or an ambiguous term) → the picker over the filtered set.
# Esc in the blink picker (rc 130) cancels outright; only an *unavailable* blink
# (rc 1) falls back to the bash picker.
CHOICE="$(_ia_pick_blink "$FILT_FILE")"; PICK_RC=$?
if (( PICK_RC == 130 )); then
    exit 0
elif (( PICK_RC != 0 )); then
    CHOICE="$(_ia_pick_bash "$FILT_FILE")" || exit 0
fi
[[ -n "$CHOICE" ]] || exit 0
_ia_route "$CHOICE"
