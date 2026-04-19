#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

if dpkg -s tmux >/dev/null 2>&1; then
    ok "tmux already installed"
else
    info "apt install tmux"
    sudo apt-get update -qq
    sudo apt-get install -y -qq tmux
fi

ok "40-tmux done"
