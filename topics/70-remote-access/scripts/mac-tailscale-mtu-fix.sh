#!/usr/bin/env bash
# mac-tailscale-mtu-fix.sh — set MTU 1200 on the macOS Tailscale interface.
#
# Context: OpenSSH 9.6+ negotiates sntrup761x25519-sha512 (post-quantum KEX),
# producing ~3-4 KB packets. The Tailscale WireGuard tunnel has MTU 1280 by
# default — silent fragmentation stalls SSH at SSH2_MSG_KEX_ECDH_REPLY.
# Dropping MTU to 1200 closes the gap.
#
# Why this isn't automated inside install.mac.sh:
# - Tailscale on macOS ships as a GUI .app (brew cask). The daemon is managed
#   by the app itself; there's no systemd drop-in equivalent.
# - The Tailscale interface is `utun<N>` where N varies per session.
# - A LaunchDaemon running on every boot + network.plist watcher would work,
#   but is invasive. Chosen approach: run this script manually on demand.
#
# Usage:
#   sudo bash mac-tailscale-mtu-fix.sh          # sets MTU 1200 now (non-persistent)
#   # To persist: re-run after reboot or re-login.
#   # To automate: install as a LaunchDaemon (example in the README).

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "! this script needs sudo: sudo bash $0"
    exit 1
fi

if ! command -v tailscale >/dev/null 2>&1; then
    echo "! tailscale CLI not found — install Tailscale.app first"
    exit 1
fi

# Find the Tailscale interface. `tailscale status` prints the interface IP
# but not the device name. Use ifconfig to match the utun carrying that IP.
ts_ip4="$(tailscale ip -4 2>/dev/null || true)"
if [[ -z "$ts_ip4" ]]; then
    echo "! tailscale IP not found — run 'tailscale up' first"
    exit 1
fi

# Walk utun* devices looking for the one bound to this IP.
ts_iface=""
for iface in $(ifconfig -l); do
    if [[ "$iface" == utun* ]]; then
        if ifconfig "$iface" 2>/dev/null | grep -qF "inet $ts_ip4"; then
            ts_iface="$iface"
            break
        fi
    fi
done

if [[ -z "$ts_iface" ]]; then
    echo "! could not identify the Tailscale interface (IP $ts_ip4)"
    exit 1
fi

current_mtu="$(ifconfig "$ts_iface" | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')"
echo "→ Tailscale interface: $ts_iface (current MTU: $current_mtu)"

if [[ "$current_mtu" == "1200" ]]; then
    echo "✓ MTU is already 1200 — nothing to do"
    exit 0
fi

echo "→ setting MTU $ts_iface -> 1200"
ifconfig "$ts_iface" mtu 1200

echo "✓ MTU set. Verify with: ifconfig $ts_iface | grep mtu"
echo "! This change does NOT persist across reboots / re-logins."
echo "  Re-run this script after boot, or install as a LaunchDaemon (see README)."
