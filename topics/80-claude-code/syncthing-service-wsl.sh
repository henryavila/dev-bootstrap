#!/usr/bin/env bash
# Custom installer: syncthing user-service on WSL.
# Enables the user systemd unit + linger so it survives logout.

check() {
    systemctl --user is-enabled syncthing.service >/dev/null 2>&1 \
        && systemctl --user is-active syncthing.service >/dev/null 2>&1
}

install() {
    if command -v loginctl >/dev/null 2>&1; then
        if ! loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
            sudo loginctl enable-linger "$USER" 2>/dev/null \
                || echo "[syncthing-service-wsl] loginctl enable-linger failed (non-fatal)" >&2
        fi
    fi
    if ! systemctl --user enable --now syncthing.service 2>/dev/null; then
        echo "[syncthing-service-wsl] systemctl --user failed — starting syncthing manually" >&2
        syncthing serve --no-browser >/dev/null 2>&1 &
        disown
    fi
}

verify() {
    pgrep -u "$USER" -f 'syncthing' >/dev/null 2>&1
}

rollback() {
    systemctl --user disable --now syncthing.service 2>/dev/null || true
}
