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
        echo "[docker-post-setup] enabling docker.service via systemd"
        sudo systemctl enable --now docker.service >/dev/null 2>&1 \
            || echo "[docker-post-setup] systemctl enable failed — start manually with 'sudo service docker start'" >&2
    else
        echo "[docker-post-setup] non-systemd WSL — start daemon on demand with 'sudo service docker start'"
    fi
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
