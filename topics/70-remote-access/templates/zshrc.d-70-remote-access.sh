# ~/.zshrc.d/70-remote-access.sh — Tailscale shortcuts.
# Deployed only when INCLUDE_REMOTE=1.

command -v tailscale >/dev/null 2>&1 || return 0

# Common Tailscale commands — status-first, shortest names match usage frequency.
alias ts='tailscale status'
alias tip='tailscale ip -4'
alias tup='sudo tailscale up'
alias tdown='sudo tailscale down'
alias tnetcheck='tailscale netcheck'
alias tping='tailscale ping'

# Tailscale's own SSH replacement (bypasses the local sshd; handy for
# automatic key management across the mesh — NO OpenSSH keys to curate).
alias tssh='tailscale ssh'

# tip-of <hostname> → the Tailscale IP of that host, no manual grep.
tip-of() {
    tailscale status | awk -v h="$1" '$2 == h {print $1}'
}
