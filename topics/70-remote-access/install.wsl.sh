#!/usr/bin/env bash
# 70-remote-access (WSL): sshd, Tailscale, mosh, sudoers NOPASSWD, systemd in WSL.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

# Ensure systemd is enabled in /etc/wsl.conf
wsl_conf="/etc/wsl.conf"
if ! sudo grep -q '^\s*systemd\s*=\s*true' "$wsl_conf" 2>/dev/null; then
    info "enabling systemd in $wsl_conf (requires 'wsl --shutdown' to apply)"
    sudo tee -a "$wsl_conf" >/dev/null <<'EOF'

[boot]
systemd=true
EOF
    warn "you must run 'wsl --shutdown' from PowerShell and relaunch for systemd to activate"
fi

# sshd
if ! dpkg -s openssh-server >/dev/null 2>&1; then
    info "installing openssh-server"
    sudo apt-get update -qq
    sudo apt-get install -y -qq openssh-server
else
    ok "openssh-server already installed"
fi
sudo systemctl enable --now ssh 2>/dev/null || warn "systemctl unavailable — will start after wsl shutdown"

# mosh
if ! dpkg -s mosh >/dev/null 2>&1; then
    info "installing mosh"
    sudo apt-get install -y -qq mosh
else
    ok "mosh already installed"
fi

# Tailscale
if ! command -v tailscale >/dev/null 2>&1; then
    info "installing tailscale"
    curl -fsSL https://tailscale.com/install.sh | sh
else
    ok "tailscale already installed"
fi

# NOPASSWD sudoers entry — idempotent
sudoers_file="/etc/sudoers.d/10-${USER}-nopasswd"
line="${USER} ALL=(ALL) NOPASSWD: ALL"
if [[ ! -f "$sudoers_file" ]] || ! sudo grep -qF "$line" "$sudoers_file"; then
    info "adding NOPASSWD sudoers entry at $sudoers_file"
    echo "$line" | sudo tee "$sudoers_file" >/dev/null
    sudo chmod 0440 "$sudoers_file"
else
    ok "NOPASSWD sudoers already set"
fi

ok "70-remote-access (wsl) done"
warn "tailscale up requires interactive auth: 'sudo tailscale up'"
