#!/usr/bin/env bash
# Custom installer: enable systemd in /etc/wsl.conf.
# Requires `wsl --shutdown` from PowerShell to apply.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/log.sh"

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
    ok "systemd enabled in /etc/wsl.conf"
    # systemd-binfmt does not ship a WSLInterop rule. Without it, PE binaries
    # (powershell.exe, cmd.exe, clip.exe) fail with "Exec format error" once
    # systemd is PID 1 — fonts, mkcert Windows CA import, and WT config break.
    if [[ ! -s /etc/binfmt.d/WSLInterop.conf ]]; then
        echo ':WSLInterop:M::MZ::/init:PF' | sudo tee /etc/binfmt.d/WSLInterop.conf >/dev/null
        sudo chmod 0644 /etc/binfmt.d/WSLInterop.conf
    fi
    if [[ -w /proc/sys/fs/binfmt_misc/register && ! -e /proc/sys/fs/binfmt_misc/WSLInterop ]]; then
        echo ':WSLInterop:M::MZ::/init:PF' | sudo tee /proc/sys/fs/binfmt_misc/register >/dev/null || true
    fi
    followup critical "WSL systemd will not activate until you run \`wsl --shutdown\` from Windows PowerShell, then reopen Ubuntu. Without that, docker / mesh services / user linger stay degraded."
}

verify() {
    check
}

repair() { install; }

rollback() {
    # Editing /etc/wsl.conf to remove our addition is fragile; leave it.
    :
}
