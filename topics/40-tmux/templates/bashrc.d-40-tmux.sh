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

# `tm` — attach-or-create the canonical 'main' session.
# `-A` on new-session behaves like attach-session when the session
# already exists, so the first call spawns and every subsequent
# call re-enters the same tmux. Good default for "just give me
# tmux" without naming anything.
alias tm='tmux new -A -s main'
