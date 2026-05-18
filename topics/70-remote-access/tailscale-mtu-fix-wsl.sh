#!/usr/bin/env bash
# Custom installer: tailscaled systemd drop-in forcing tailscale0 MTU=1200.
# Prevents the SSH KEX hang against OpenSSH 9.6+ peers (post-quantum KEX
# packets ~3-4 KB are silently fragmented on WireGuard's default 1280 MTU).

_dropin_dir() { printf '%s\n' "/etc/systemd/system/tailscaled.service.d"; }
_dropin_file() { printf '%s\n' "$(_dropin_dir)/mtu.conf"; }
_dropin_content() {
    cat <<'EOF'
[Service]
ExecStartPost=/usr/sbin/ip link set tailscale0 mtu 1200
EOF
}

check() {
    local f want got
    f="$(_dropin_file)"
    [[ -f "$f" ]] || return 1
    want="$(_dropin_content)"
    got="$(sudo cat "$f" 2>/dev/null || true)"
    [[ "$want" == "$got" ]]
}

install() {
    local d f
    d="$(_dropin_dir)"
    f="$(_dropin_file)"
    sudo mkdir -p "$d"
    _dropin_content | sudo tee "$f" >/dev/null
    if command -v systemctl >/dev/null 2>&1; then
        sudo systemctl daemon-reload 2>/dev/null \
            || echo "[tailscale-mtu] daemon-reload failed (systemd not ready in this WSL session?)" >&2
        if sudo systemctl is-active tailscaled >/dev/null 2>&1; then
            sudo systemctl restart tailscaled \
                || echo "[tailscale-mtu] tailscaled restart failed — retry manually" >&2
        fi
    fi
}

verify() {
    check
}

rollback() {
    local f
    f="$(_dropin_file)"
    if [[ -f "$f" ]]; then
        sudo rm -f "$f"
        command -v systemctl >/dev/null 2>&1 && sudo systemctl daemon-reload 2>/dev/null || true
    fi
}
