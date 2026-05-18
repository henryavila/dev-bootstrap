#!/usr/bin/env bash
# Custom installer: enable systemd in /etc/wsl.conf.
# Requires `wsl --shutdown` from PowerShell to apply.

check() {
    sudo grep -q '^\s*systemd\s*=\s*true' /etc/wsl.conf 2>/dev/null
}

install() {
    sudo tee -a /etc/wsl.conf >/dev/null <<'EOF'

[boot]
systemd=true
EOF
    echo "[systemd-wsl] systemd enabled in /etc/wsl.conf"
    echo "[systemd-wsl] you must run 'wsl --shutdown' from PowerShell + relaunch for it to activate" >&2
}

verify() {
    check
}

rollback() {
    # Editing /etc/wsl.conf to remove our addition is fragile; leave it.
    :
}
