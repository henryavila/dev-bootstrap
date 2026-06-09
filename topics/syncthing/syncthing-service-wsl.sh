#!/usr/bin/env bash
# Custom installer: syncthing user-service on WSL.
# Enables the user systemd unit + linger so it survives logout.

check() {
    # Primary: managed user unit is enabled + active.
    if systemctl --user is-enabled syncthing.service >/dev/null 2>&1 \
        && systemctl --user is-active syncthing.service >/dev/null 2>&1; then
        return 0
    fi
    # Fallback: install()'s manual path may have backgrounded a live syncthing
    # process when systemd was unavailable; honor that state so we don't churn.
    pgrep -u "$USER" -f 'syncthing serve' >/dev/null 2>&1
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
        # Confirm the fallback process is actually alive; otherwise report
        # install failure rather than silently returning 0 from disown.
        if ! pgrep -u "$USER" -f 'syncthing serve' >/dev/null 2>&1; then
            echo "[syncthing-service-wsl] manual syncthing start did not stay alive" >&2
            return 1
        fi
    fi
}

verify() {
    pgrep -u "$USER" -f 'syncthing serve' >/dev/null 2>&1
}

rollback() {
    systemctl --user disable --now syncthing.service 2>/dev/null || true
}
