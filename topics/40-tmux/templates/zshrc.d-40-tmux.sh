# shellcheck shell=bash
# ~/.zshrc.d/40-tmux.sh — generic tmux shortcuts shipped with
# dev-bootstrap. Personal project-specific session aliases (e.g. `th`
# for a session named 'arch') belong in your private dotfiles, NOT
# here — this file is what everyone using the bootstrap receives.

command -v tmux >/dev/null 2>&1 || return 0

__dev_bootstrap_tmux_auto_main_done=0

__dev_bootstrap_tmux_auto_main_ready() {
    # Dormant by default: auto-attaching "main" proved unstable in
    # Moshi and normal terminal login flows. Keep the implementation for
    # explicit experiments only. See docs/INACTIVE_FEATURES.md.
    [ "${DEV_BOOTSTRAP_TMUX_AUTO_MAIN:-0}" = "1" ] || return 1
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

__dev_bootstrap_tmux_auto_main_remove_precmd() {
    # shellcheck disable=SC2206 # zsh array filter syntax; quoting changes semantics.
    precmd_functions=(${precmd_functions:#__dev_bootstrap_tmux_auto_main_precmd})
}

__dev_bootstrap_tmux_auto_main_late() {
    __dev_bootstrap_tmux_auto_main_scheduled=0
    if __dev_bootstrap_tmux_auto_main || ! __dev_bootstrap_tmux_auto_main_ready; then
        __dev_bootstrap_tmux_auto_main_remove_precmd
    fi
}

__dev_bootstrap_tmux_auto_main_precmd() {
    if __dev_bootstrap_tmux_auto_main || ! __dev_bootstrap_tmux_auto_main_ready; then
        __dev_bootstrap_tmux_auto_main_remove_precmd
        return 0
    fi

    if [ "${__dev_bootstrap_tmux_auto_main_scheduled:-0}" = "0" ] \
        && zmodload zsh/sched 2>/dev/null; then
        __dev_bootstrap_tmux_auto_main_scheduled=1
        sched +0 __dev_bootstrap_tmux_auto_main_late
    fi
}

if __dev_bootstrap_tmux_auto_main_ready; then
    if [ -t 0 ] && [ -t 1 ]; then
        __dev_bootstrap_tmux_auto_main
    else
        case " ${precmd_functions[*]-} " in
            *" __dev_bootstrap_tmux_auto_main_precmd "*) ;;
            *) precmd_functions+=(__dev_bootstrap_tmux_auto_main_precmd) ;;
        esac
    fi
fi

__dev_bootstrap_tmux_update_cwd() {
    [ -n "${TMUX:-}" ] || return 0
    tmux set-option -p -q @dev_bootstrap_pane_cwd "$PWD" >/dev/null 2>&1 || true
}

__dev_bootstrap_tmux_update_cwd
case " ${chpwd_functions[*]-} " in
    *" __dev_bootstrap_tmux_update_cwd "*) ;;
    *) chpwd_functions+=(__dev_bootstrap_tmux_update_cwd) ;;
esac
case " ${precmd_functions[*]-} " in
    *" __dev_bootstrap_tmux_update_cwd "*) ;;
    *) precmd_functions+=(__dev_bootstrap_tmux_update_cwd) ;;
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
