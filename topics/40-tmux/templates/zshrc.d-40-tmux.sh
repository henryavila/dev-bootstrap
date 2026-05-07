# shellcheck shell=bash
# ~/.zshrc.d/40-tmux.sh — generic tmux shortcuts shipped with
# dev-bootstrap. Personal project-specific session aliases (e.g. `th`
# for a session named 'arch') belong in your private dotfiles, NOT
# here — this file is what everyone using the bootstrap receives.

command -v tmux >/dev/null 2>&1 || return 0

__dev_bootstrap_tmux_update_cwd() {
    [ -n "${TMUX:-}" ] || return 0
    tmux set-option -p -q @dev_bootstrap_pane_cwd "$PWD" >/dev/null 2>&1 || true
}

__dev_bootstrap_tmux_short_host() {
    hostname -s 2>/dev/null || hostname 2>/dev/null || printf '%s' unknown
}

__dev_bootstrap_tmux_update_ssh_context() {
    [ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ] || return 0

    local scope='-g'
    [ -n "${TMUX:-}" ] && scope='-p'

    tmux set-option "$scope" -q @dev_bootstrap_ssh_context \
        "${USER:-user}@$(__dev_bootstrap_tmux_short_host)" >/dev/null 2>&1 || true
}

__dev_bootstrap_tmux_update_cwd
__dev_bootstrap_tmux_update_ssh_context
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
alias ta='tmux attach -t'
alias tn='tmux new -s'

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
