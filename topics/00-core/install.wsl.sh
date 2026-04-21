#!/usr/bin/env bash
# 00-core (WSL): minimal tooling used by every later topic.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

pkgs=(
    git
    curl
    wget
    ca-certificates
    gnupg
    build-essential
    jq
    unzip
    gettext-base
)

# Check which packages are missing FIRST so we only invoke sudo when we
# actually need it. Re-running this topic on a fully-provisioned machine
# should succeed even without a sudo ticket — it's a pure no-op.
missing=()
for p in "${pkgs[@]}"; do
    if dpkg -s "$p" >/dev/null 2>&1; then
        ok "$p already installed"
    else
        missing+=("$p")
    fi
done

if [[ "${#missing[@]}" -gt 0 ]]; then
    info "apt update"
    sudo apt-get update -qq
    info "installing: ${missing[*]}"
    sudo apt-get install -y -qq "${missing[@]}"
fi

ok "00-core done"
