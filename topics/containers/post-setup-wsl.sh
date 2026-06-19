#!/usr/bin/env bash
# Custom installer for the WSL Docker post-setup step.
# Engine sources this file inside a subshell and calls install(), check(), verify().
#
# What it does:
#   1. Adds $USER to the `docker` group so `docker` runs without sudo.
#      Effective on next login / after `newgrp docker`.
#   2. Enables and starts docker.service via systemd (silently falls through
#      on non-systemd WSL — user starts via `sudo service docker start`).
#
# Idempotent: check() returns 0 if the user is already in the docker group,
# which is the minimum-viable state for the rest of the topic to be useful.

check() {
    # Group membership is the durable side-effect. systemd-enabled state is
    # best-effort and not part of the idempotency contract.
    if id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        return 0
    fi
    return 1
}

install() {
    if ! getent group docker >/dev/null 2>&1; then
        echo "[docker-post-setup] docker group missing — package install may have failed" >&2
        return 1
    fi

    if ! id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        echo "[docker-post-setup] adding $USER to docker group"
        sudo usermod -aG docker "$USER" \
            || { echo "[docker-post-setup] usermod failed" >&2; return 1; }
        echo "[docker-post-setup] log out/in or run 'newgrp docker' to use docker without sudo"
    fi

    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        echo "[docker-post-setup] starting docker.service (boot-state via services.default)"
        sudo systemctl start docker.service >/dev/null 2>&1 \
            || echo "[docker-post-setup] systemctl start failed — start manually with 'sudo service docker start'" >&2
        # T-006: boot autostart is decoupled from install — apply it from the
        # per-host services.default via the shared services lib, not enable --now.
        _apply_boot_state docker
    else
        echo "[docker-post-setup] non-systemd WSL — start daemon on demand with 'sudo service docker start'"
    fi
}

# T-006: reconcile docker's boot-state toward services.default (svc_enable/
# svc_disable). Isolated subshell + best-effort; never fatal.
_apply_boot_state() {
    local recon
    recon="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/scripts/lib/services/reconcile.sh"
    [[ -f "$recon" ]] || return 0
    ( . "$recon" && services_reconcile_one "$1" ) 2>/dev/null || true
}

verify() {
    check
}

rollback() {
    if id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        echo "[docker-post-setup] rolling back: removing $USER from docker group"
        sudo deluser "$USER" docker 2>/dev/null || true
    fi
}
