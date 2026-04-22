#!/usr/bin/env bash
# 70-remote-access (WSL): sshd, Tailscale, mosh, sudoers NOPASSWD, systemd in WSL.
#
# Tailscale MTU fix: a drop-in systemd overlay forces tailscale0 MTU to 1200
# on every tailscaled start. Without this, SSH over Tailscale hangs at
# SSH2_MSG_KEX_ECDH_REPLY when the peer runs OpenSSH 9.6+ (post-quantum KEX
# packets ~3-4 KB are silently fragmented on the WireGuard MTU-1280 tunnel).
# See README.md for the full diagnosis.
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

# ---------- Tailscale MTU fix (prevents SSH KEX PQ hang) ----------
# Drop-in reduces tailscale0 MTU from 1280 (WireGuard default) to 1200,
# giving enough headroom for post-quantum KEX packets to avoid silent
# fragmentation. Applied every time tailscaled starts, so it survives
# reboots + re-installs of Tailscale itself.
mtu_dropin_dir="/etc/systemd/system/tailscaled.service.d"
mtu_dropin="$mtu_dropin_dir/mtu.conf"
mtu_dropin_content='[Service]
ExecStartPost=/usr/sbin/ip link set tailscale0 mtu 1200
'

needs_write=0
if [[ ! -f "$mtu_dropin" ]]; then
    needs_write=1
elif ! echo -n "$mtu_dropin_content" | sudo diff -q - "$mtu_dropin" >/dev/null 2>&1; then
    needs_write=1
fi

if [[ "$needs_write" -eq 1 ]]; then
    info "writing tailscaled MTU drop-in at $mtu_dropin"
    sudo mkdir -p "$mtu_dropin_dir"
    echo -n "$mtu_dropin_content" | sudo tee "$mtu_dropin" >/dev/null
    sudo systemctl daemon-reload 2>/dev/null || warn "daemon-reload failed (systemd not ready in this WSL session?)"
    # Restart tailscaled only if already running — otherwise next start will pick up the change
    if sudo systemctl is-active tailscaled >/dev/null 2>&1; then
        info "restarting tailscaled to apply MTU fix"
        sudo systemctl restart tailscaled || warn "tailscaled restart failed — retry manually"
    fi
    ok "tailscale0 MTU=1200 will be enforced by tailscaled on every start"
else
    ok "tailscaled MTU drop-in already correct"
fi

# Note: legacy NOPASSWD cleanup moved to bootstrap.sh (unconditional)
# since v2026-04-22 hotfix — see there for context.

ok "70-remote-access (wsl) done"

# Tailscale needs interactive OAuth/auth-key input. Always a manual
# step — bootstrap can't complete it.
if ! tailscale status >/dev/null 2>&1; then
    followup manual \
"Tailscale installed but not authenticated on this machine.
Run:  sudo tailscale up
  (opens browser → pick the tailnet to join; authkey also accepted)"
fi
