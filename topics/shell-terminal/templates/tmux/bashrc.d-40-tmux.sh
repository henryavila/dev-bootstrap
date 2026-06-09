# shellcheck shell=bash
# ~/.bashrc.d/40-tmux.sh — generic tmux shortcuts shipped with
# mesh-workstation. Personal project-specific session aliases (e.g. `th`
# for a session named 'arch') belong in your private dotfiles, NOT
# here — this file is what everyone using the bootstrap receives.

command -v tmux >/dev/null 2>&1 || return 0

__dev_bootstrap_tmux_auto_main_done=0

__dev_bootstrap_tmux_auto_main_ready() {
    # Dormant by default: auto-attaching "main" proved unstable in
    # Moshi and normal terminal login flows. Keep the implementation for
    # explicit experiments only. See docs/INACTIVE_FEATURES.md.
    [ "${MESH_TMUX_AUTO_MAIN:-0}" = "1" ] || return 1
    case "$-" in *i*) ;; *) return 1 ;; esac
    [ -z "${TMUX:-}" ] || return 1
    [ "${__dev_bootstrap_tmux_auto_main_done:-0}" = "0" ] || return 1
}

__dev_bootstrap_tmux_auto_main() {
    __dev_bootstrap_tmux_auto_main_ready || return 1
    [ -t 0 ] && [ -t 1 ] || return 1

    __dev_bootstrap_tmux_auto_main_done=1
    tmux new-session -A -s main
}

__dev_bootstrap_tmux_auto_main_remove_prompt() {
    case ";${PROMPT_COMMAND:-};" in
        *";__dev_bootstrap_tmux_auto_main_prompt;"*)
            local __dev_bootstrap_tmux_pc
            __dev_bootstrap_tmux_pc=";${PROMPT_COMMAND:-};"
            __dev_bootstrap_tmux_pc="${__dev_bootstrap_tmux_pc//;__dev_bootstrap_tmux_auto_main_prompt;/;}"
            __dev_bootstrap_tmux_pc="${__dev_bootstrap_tmux_pc#;}"
            __dev_bootstrap_tmux_pc="${__dev_bootstrap_tmux_pc%;}"
            PROMPT_COMMAND="$__dev_bootstrap_tmux_pc"
            ;;
    esac
}

__dev_bootstrap_tmux_auto_main_prompt() {
    if __dev_bootstrap_tmux_auto_main || ! __dev_bootstrap_tmux_auto_main_ready; then
        __dev_bootstrap_tmux_auto_main_remove_prompt
    fi
}

if __dev_bootstrap_tmux_auto_main_ready; then
    if [ -t 0 ] && [ -t 1 ]; then
        __dev_bootstrap_tmux_auto_main
    else
        case ";${PROMPT_COMMAND:-};" in
            *";__dev_bootstrap_tmux_auto_main_prompt;"*) ;;
            *) PROMPT_COMMAND="__dev_bootstrap_tmux_auto_main_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
        esac
    fi
fi

__dev_bootstrap_tmux_update_cwd() {
    [ -n "${TMUX:-}" ] || return 0
    tmux set-option -p -q @dev_bootstrap_pane_cwd "$PWD" >/dev/null 2>&1 || true
}

__dev_bootstrap_tmux_update_cwd
case ";${PROMPT_COMMAND:-};" in
    *";__dev_bootstrap_tmux_update_cwd;"*) ;;
    *) PROMPT_COMMAND="__dev_bootstrap_tmux_update_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
esac

# List / attach / create — short forms of the usual incantations.
alias tl='tmux ls'
alias tn='tmux new -s'

ta() {
    [ "$#" -gt 0 ] || { printf 'usage: ta <session>\n' >&2; return 2; }

    if [ -n "${TMUX:-}" ]; then
        tmux switch-client -t "$1"
    else
        tmux attach -t "$1"
    fi
}

tmux_project() {
    [ "$#" -eq 2 ] || { printf 'usage: tmux_project <session> <dir>\n' >&2; return 2; }

    local session="$1"
    local dir="$2"

    if [ ! -d "$dir" ]; then
        printf 'tmux_project: directory not found: %s\n' "$dir" >&2
        return 1
    fi

    if [ -n "${TMUX:-}" ]; then
        if tmux has-session -t "$session" 2>/dev/null; then
            tmux switch-client -t "$session"
        else
            tmux new-session -d -s "$session" -c "$dir" && tmux switch-client -t "$session"
        fi
    else
        tmux new-session -A -s "$session" -c "$dir"
    fi
}

# `td` — detach from current session WITHOUT killing it. Equivalent to
# the `prefix d` keybind, but works as a regular shell command (useful
# in scripts and one-liners).
alias td='tmux detach'

# `tm` — go to the canonical 'main' session.
# Outside tmux, `new-session -A` attaches if main exists or creates it.
# Inside tmux, switch the current client instead of nesting a second tmux
# client inside the pane.
tm() {
    if [ -n "${TMUX:-}" ]; then
        if tmux has-session -t main 2>/dev/null; then
            tmux switch-client -t main
        else
            tmux new-session -d -s main && tmux switch-client -t main
        fi
    else
        tmux new-session -A -s main
    fi
}

# Tab-complete live tmux session names for `ta`. `ta` is a function, not an
# alias to `tmux attach`, so nothing completes session names for it by default.
_mesh_tmux_sessions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local sessions
    sessions="$(tmux list-sessions -F '#{session_name}' 2>/dev/null)"
    mapfile -t COMPREPLY < <(compgen -W "$sessions" -- "$cur")
}
complete -F _mesh_tmux_sessions ta
