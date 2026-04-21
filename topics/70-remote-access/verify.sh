#!/usr/bin/env bash
set -euo pipefail

# Ensure brew-managed binaries are visible when verify runs from a
# non-interactive shell (SSH, CI) where ~/.zshrc / ~/.bashrc aren't loaded.
# brew prefix varies by host: /opt/homebrew (Apple Silicon), /usr/local (Intel),
# or a custom location like /Volumes/External/homebrew. Probe all candidates.
for _brew_prefix in /opt/homebrew /usr/local /Volumes/External/homebrew; do
    [[ -d "$_brew_prefix/bin" ]] && export PATH="$_brew_prefix/bin:$PATH"
done

fail_count=0
check() {
    if command -v "$1" >/dev/null 2>&1; then
        echo "  ✓ $1"
    else
        echo "  ✗ $1 MISSING"
        fail_count=$((fail_count + 1))
    fi
}

check ssh
check mosh

# Tailscale: on Mac the .app binary lives inside /Applications and the
# CLI isn't added to PATH by default. Accept either presence as installed.
if command -v tailscale >/dev/null 2>&1; then
    echo "  ✓ tailscale (CLI in PATH)"
elif [[ "$(uname -s)" == "Darwin" ]] && [[ -d "/Applications/Tailscale.app" ]]; then
    echo "  ✓ Tailscale.app (add '/Applications/Tailscale.app/Contents/MacOS' to PATH to get CLI)"
else
    echo "  ✗ tailscale MISSING"
    fail_count=$((fail_count + 1))
fi

# Tailscale MTU drop-in (WSL/Linux only)
# Presence check — we don't fail if absent (topic may have been run before this fix existed).
if [[ "$(uname -s)" == "Linux" ]]; then
    mtu_dropin="/etc/systemd/system/tailscaled.service.d/mtu.conf"
    if [[ -f "$mtu_dropin" ]]; then
        if grep -q 'mtu 1200' "$mtu_dropin" 2>/dev/null; then
            echo "  ✓ tailscale MTU drop-in present (mtu=1200)"
        else
            echo "  ! tailscale MTU drop-in present but content unexpected — inspect $mtu_dropin"
        fi
        # If tailscale0 is up, verify actual MTU applied
        if ip link show tailscale0 >/dev/null 2>&1; then
            actual_mtu="$(ip link show tailscale0 | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')"
            if [[ "$actual_mtu" == "1200" ]]; then
                echo "  ✓ tailscale0 MTU = $actual_mtu (applied)"
            else
                echo "  ! tailscale0 MTU = $actual_mtu (expected 1200 — drop-in may not have run; restart tailscaled)"
            fi
        fi
    else
        echo "  ! tailscale MTU drop-in ABSENT — SSH via Tailscale may hang. Re-run: ONLY_TOPICS=70-remote-access bash bootstrap.sh"
    fi
fi

[[ "$fail_count" -eq 0 ]]
