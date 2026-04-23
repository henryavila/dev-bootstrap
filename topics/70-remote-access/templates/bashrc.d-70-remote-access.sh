# shellcheck shell=bash
# ~/.bashrc.d/70-remote-access.sh — Tailscale shortcuts.
# Mirror of the zsh fragment.

command -v tailscale >/dev/null 2>&1 || return 0

alias ts='tailscale status'
alias tip='tailscale ip -4'
alias tup='sudo tailscale up'
alias tdown='sudo tailscale down'
alias tnetcheck='tailscale netcheck'
alias tping='tailscale ping'
alias tssh='tailscale ssh'

tip-of() {
    tailscale status | awk -v h="$1" '$2 == h {print $1}'
}
