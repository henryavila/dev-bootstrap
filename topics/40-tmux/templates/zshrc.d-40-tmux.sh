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

__dev_bootstrap_tmux_update_cwd
case " ${chpwd_functions[*]-} " in
    *" __dev_bootstrap_tmux_update_cwd "*) ;;
    *) chpwd_functions+=(__dev_bootstrap_tmux_update_cwd) ;;
esac
case " ${precmd_functions[*]-} " in
    *" __dev_bootstrap_tmux_update_cwd "*) ;;
    *) precmd_functions+=(__dev_bootstrap_tmux_update_cwd) ;;
esac

__dev_bootstrap_tmux_ssh_context_from_args() {
    local remote_user="${USER:-user}" host="" arg opt

    while [ "$#" -gt 0 ]; do
        arg="$1"
        shift

        case "$arg" in
            --)
                [ "$#" -gt 0 ] && host="$1"
                break
                ;;
            -l)
                if [ "$#" -gt 0 ]; then
                    remote_user="$1"
                    shift
                fi
                ;;
            -l?*)
                remote_user="${arg#-l}"
                ;;
            -o)
                if [ "$#" -gt 0 ]; then
                    opt="$1"
                    shift
                    case "$opt" in
                        User=*|user=*) remote_user="${opt#*=}" ;;
                    esac
                fi
                ;;
            -oUser=*|-ouser=*)
                remote_user="${arg#*=}"
                ;;
            -[46AaCfGgKkMNnqsTtVvXxYy]*)
                ;;
            -[bBcDEeFIiJLPmOopQRSWw])
                [ "$#" -gt 0 ] && shift
                ;;
            -[bBcDEeFIiJLPmOopQRSWw]?*)
                ;;
            -*)
                ;;
            *@*)
                remote_user="${arg%@*}"
                host="${arg#*@}"
                break
                ;;
            *)
                host="$arg"
                break
                ;;
        esac
    done

    [ -n "$host" ] || return 1
    printf '%s@%s\n' "$remote_user" "$host"
}

if command -v ssh >/dev/null 2>&1; then
    ssh() {
        local context="" rc
        context="$(__dev_bootstrap_tmux_ssh_context_from_args "$@" 2>/dev/null || true)"

        if [ -n "${TMUX:-}" ] && [ -n "$context" ]; then
            tmux set-option -p -q @dev_bootstrap_outbound_ssh_context \
                "$context" >/dev/null 2>&1 || true
            command ssh "$@"
            rc=$?
            tmux set-option -p -q -u @dev_bootstrap_outbound_ssh_context \
                >/dev/null 2>&1 || true
            return "$rc"
        fi

        command ssh "$@"
    }
fi

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
