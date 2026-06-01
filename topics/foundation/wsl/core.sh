#!/usr/bin/env bash
# foundation/base (WSL): minimal tooling used by every later topic.
# Custom item contract — engine sources this and calls check()/install()/verify().

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../../scripts/lib/log.sh"

CORE_PKGS=(
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

check() {
    local p
    for p in "${CORE_PKGS[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 || return 1
    done
    return 0
}

install() {
    # Check which packages are missing FIRST so we only invoke sudo when we
    # actually need it. Re-running on a fully-provisioned machine is a pure
    # no-op that succeeds even without a sudo ticket.
    local p
    local missing=()
    for p in "${CORE_PKGS[@]}"; do
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
    ok "foundation/base done"
}

verify() {
    check
}

rollback() {
    # Core packages are shared by every topic — never auto-remove them.
    :
}
