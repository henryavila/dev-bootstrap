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

# Functional probe: the runnable tools install() actually guarantees on PATH.
# `dpkg -s` only asserts the dpkg DB says "installed" — a package can be
# registered while its binary was manually deleted, diverted, or left
# half-configured (rc=0 keep on a broken tree). Each entry below maps to a
# binary that the corresponding CORE_PKGS package is *guaranteed* to ship:
#   git/curl/wget/jq/unzip  → eponymous binary
#   gnupg                   → gpg     (hard dep of the gnupg meta-pkg)
#   gettext-base            → envsubst
#   build-essential         → gcc + make (hard deps; the whole point of the pkg)
# ca-certificates is data-only (no binary) and stays presence-only via dpkg.
# All of these resolve on a healthy WSL box, so this never false-fails the
# currently-passing state — it only catches a package that claims installed
# but whose tool can't actually run. sudo-free; bash 3.2 safe.
CORE_BINS=(
    git
    curl
    wget
    gpg
    jq
    unzip
    envsubst
    gcc
    make
)

check() {
    local p
    for p in "${CORE_PKGS[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 || return 1
    done
    local b
    for b in "${CORE_BINS[@]}"; do
        command -v "$b" >/dev/null 2>&1 || return 1
    done
    return 0
}

# Binaries each package is guaranteed to ship (space-separated; empty for
# data-only packages). Used by install() so a package that is dpkg-registered
# but whose tool can't actually run is reinstalled, keeping install() able to
# self-heal exactly the broken state check() now rejects. bash 3.2 — no assoc
# arrays, so a case lookup.
_pkg_bins() {
    case "$1" in
        git)             printf '%s' "git" ;;
        curl)            printf '%s' "curl" ;;
        wget)            printf '%s' "wget" ;;
        gnupg)           printf '%s' "gpg" ;;
        build-essential) printf '%s' "gcc make" ;;
        jq)              printf '%s' "jq" ;;
        unzip)           printf '%s' "unzip" ;;
        gettext-base)    printf '%s' "envsubst" ;;
        *)               printf '%s' "" ;;  # ca-certificates: data only
    esac
}

# A package is healthy iff dpkg says installed AND every binary it ships runs.
_pkg_healthy() {
    dpkg -s "$1" >/dev/null 2>&1 || return 1
    local b
    for b in $(_pkg_bins "$1"); do
        command -v "$b" >/dev/null 2>&1 || return 1
    done
    return 0
}

install() {
    # Check which packages are missing/broken FIRST so we only invoke sudo when
    # we actually need it. Re-running on a fully-provisioned machine is a pure
    # no-op that succeeds even without a sudo ticket. A package that is
    # dpkg-registered but whose guaranteed tool is absent counts as missing so
    # `apt-get install` reinstalls (and repairs) it.
    local p
    local missing=()
    for p in "${CORE_PKGS[@]}"; do
        if _pkg_healthy "$p"; then
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
