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
    # systemd drop-ins in /etc/systemd/system/*.service.d/ are root:root
    # mode 0644 by default — world-readable, so sudo is unnecessary for
    # the read. Keeping check() sudo-free lets the menu scanner probe
    # state with zero password friction.
    local f want got
    f="$(_dropin_file)"
    [[ -f "$f" ]] || return 1
    want="$(_dropin_content)"
    got="$(cat "$f" 2>/dev/null || true)"
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

# Functional probe: the drop-in only changes behaviour AFTER a
# daemon-reload + tailscaled restart applies `ip link set tailscale0 mtu N`.
# install() attempts that, but on WSL it can no-op (systemd not ready →
# the script itself warns "retry manually"), leaving the file correct on
# disk while tailscale0 still runs the WireGuard default (1280). A
# content-only check() then KEEPs forever and the SSH-KEX hang persists.
# So verify()/--repair assert the LIVE state too: when tailscale0 exists,
# its sysfs MTU must equal the value the drop-in pins. sysfs MTU
# (/sys/class/net/<if>/mtu) is world-readable → sudo-free, satisfying the
# scanner constraint. CONSERVATIVE: if tailscale0 is absent (tailscale
# simply down) we cannot conclude the fix is unapplied, so we do NOT fail
# on that — the content check() carries the keep/skip decision and a real
# restart later applies the pinned MTU. This keeps verify() strictly
# stronger than check() without false-failing a healthy, idle install.
_pinned_mtu() {
    # Single source of truth: extract N from the drop-in's
    # `ip link set tailscale0 mtu N` line.
    _dropin_content | sed -n 's/.*mtu \([0-9][0-9]*\).*/\1/p' | head -n1
}

verify() {
    # Strong post-install / --repair probe: content sentinel + live MTU.
    check || return 1
    local sysfs want got
    sysfs="/sys/class/net/tailscale0/mtu"
    # Interface not present → tailscale is down, not misconfigured. Defer to
    # check() (already passed). Do not false-fail.
    [[ -r "$sysfs" ]] || return 0
    want="$(_pinned_mtu)"
    # Defensive: if we somehow couldn't derive the pinned value, fall back
    # to the content check we already passed rather than fail spuriously.
    [[ -n "$want" ]] || return 0
    got="$(cat "$sysfs" 2>/dev/null || true)"
    if [[ "$got" != "$want" ]]; then
        echo "[tailscale-mtu] drop-in present but tailscale0 MTU=$got (want $want) — daemon-reload+restart not applied" >&2
        return 1
    fi
    return 0
}

rollback() {
    local f
    f="$(_dropin_file)"
    if [[ -f "$f" ]]; then
        sudo rm -f "$f"
        command -v systemctl >/dev/null 2>&1 && sudo systemctl daemon-reload 2>/dev/null || true
    fi
}
