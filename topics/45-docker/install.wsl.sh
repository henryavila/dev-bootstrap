#!/usr/bin/env bash
# 45-docker (WSL): Docker Engine + Compose v2. Opt-in via INCLUDE_DOCKER=1.
#
# Uses Ubuntu's docker.io package (not docker-ce) to keep the install
# boring — no extra apt repo, no PPA, no signing-key churn. Suitable for
# dev use; production workloads should follow the official docker-ce docs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

# ---------- docker.io + compose plugin ----------
if dpkg -s docker.io >/dev/null 2>&1; then
    ok "docker.io already installed"
else
    info "apt install docker.io + docker-compose-v2"
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker.io docker-compose-v2
fi

# ---------- current user → docker group ----------
# Lets `docker` run without sudo. Takes effect on next login / `newgrp docker`.
if getent group docker >/dev/null 2>&1; then
    if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
        ok "$USER already in docker group"
    else
        info "adding $USER to docker group (effective on next login)"
        sudo usermod -aG docker "$USER"
        warn "run 'newgrp docker' or log out/in to use docker without sudo"
    fi
else
    warn "docker group not present — package install may have failed"
fi

# ---------- daemon ----------
# WSL2 with systemd enabled (/etc/wsl.conf [boot] systemd=true) uses
# systemctl. Older WSL / non-systemd boots fall back to `service`. We try
# systemctl first and silently fall through on failure — not all environments
# support enabling system services and that's OK; user can start on demand.
if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    info "enabling docker.service via systemd"
    sudo systemctl enable --now docker.service >/dev/null 2>&1 || \
        warn "systemctl enable docker.service failed — start manually with 'sudo service docker start'"
else
    info "non-systemd WSL — start daemon on demand with 'sudo service docker start'"
fi

ok "45-docker (wsl) done"
