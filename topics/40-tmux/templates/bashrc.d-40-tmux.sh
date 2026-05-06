# shellcheck shell=bash
# ~/.bashrc.d/40-tmux.sh — generic tmux shortcuts shipped with
# dev-bootstrap. Personal project-specific session aliases (e.g. `th`
# for a session named 'arch') belong in your private dotfiles, NOT
# here — this file is what everyone using the bootstrap receives.

command -v tmux >/dev/null 2>&1 || return 0

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
