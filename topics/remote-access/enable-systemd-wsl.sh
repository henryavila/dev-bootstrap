#!/usr/bin/env bash
# Custom installer: enable systemd in /etc/wsl.conf.
# Requires `wsl --shutdown` from PowerShell to apply.

check() {
    # /etc/wsl.conf is root:root mode 0644 on every Ubuntu/Debian WSL
    # image — world-readable, so sudo is unnecessary here. Keeping the
    # check sudo-free lets the menu scanner probe state with zero
    # password friction.
    grep -q '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true' /etc/wsl.conf 2>/dev/null
}

install() {
    if grep -q '^[[:space:]]*\[boot\]' /etc/wsl.conf 2>/dev/null; then
        # A [boot] section already exists (e.g. with other keys but no
        # systemd). Appending a second [boot] stanza would leave a
        # duplicate/malformed file; insert systemd=true right under the
        # existing header instead.
        sudo sed -i '0,/^[[:space:]]*\[boot\]/s//&\nsystemd=true/' /etc/wsl.conf
    else
        sudo tee -a /etc/wsl.conf >/dev/null <<'EOF'

[boot]
systemd=true
EOF
    fi
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
