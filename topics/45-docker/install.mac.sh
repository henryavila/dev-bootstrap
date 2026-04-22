#!/usr/bin/env bash
# 45-docker (mac): Colima + Docker CLI + Compose. Opt-in via INCLUDE_DOCKER=1.
#
# Colima over Docker Desktop: no license, no GUI, no forced login, no
# auto-updater. Headless Linux VM via lima; `docker` CLI talks to it over
# a socket. Stop/start on demand to reclaim RAM when idle (~2 GB VM).
#
# We install but do NOT `colima start` automatically — the VM is heavy and
# most sessions don't need Docker. User runs `colima start` when needed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

: "${BREW_BIN:?BREW_BIN not set — run through bootstrap.sh}"

for pkg in colima docker docker-compose; do
    if "$BREW_BIN" list --formula "$pkg" >/dev/null 2>&1; then
        ok "$pkg already installed"
    else
        info "brew install $pkg"
        "$BREW_BIN" install "$pkg"
    fi
done

info "colima not started — run 'colima start' when you need Docker"
info "stop the VM anytime with 'colima stop' to reclaim RAM"

ok "45-docker (mac) done"
