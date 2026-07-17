# shellcheck shell=bash
# scripts/lib/services/driver.sh — the uniform svc_* interface for `mesh
# services`. Sources the three platform backends and dispatches each verb to
# the backend named by a descriptor's `kind` (systemd|brew|launchd), so the
# runner (T-003) and TUI (T-004) call ONE interface regardless of platform:
#
#   svc_status  <kind> <scope> <target>   → prints active=/enabled=/orthogonal=
#   svc_installed <kind> <scope> <target> → rc0 when the backend target exists
#   svc_start   <kind> <scope> <target>
#   svc_stop    <kind> <scope> <target>
#   svc_restart <kind> <scope> <target>
#   svc_enable  <kind> <scope> <target>
#   svc_disable <kind> <scope> <target>
#
# Plus the CAPABILITY MATRIX the runner/TUI read to honour the two-bit
# contract (codex F-001 — never silently mutate the unrequested bit):
#   svc_orthogonal <kind>         → rc 0 if active/enabled are independent
#   svc_collateral <kind> <verb>  → prints the UNREQUESTED bit a verb ALSO
#                                   mutates on a non-orthogonal backend (empty
#                                   when the verb is clean). The runner refuses
#                                   to flip a non-empty collateral bit silently.
#
# Sourced; do not execute directly. No `set -e` (sourced lib).

_SVC_DRIVER_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/services/systemd.sh
. "$_SVC_DRIVER_HERE/systemd.sh"
# shellcheck source=scripts/lib/services/brew.sh
. "$_SVC_DRIVER_HERE/brew.sh"
# shellcheck source=scripts/lib/services/launchd.sh
. "$_SVC_DRIVER_HERE/launchd.sh"

# _svc_known_kind <kind> — rc 0 for a backend we have a driver for.
_svc_known_kind() {
    case "$1" in
        systemd|brew|launchd) return 0 ;;
        *)                    return 1 ;;
    esac
}

# _svc_drive <verb> <kind> <scope> <target> — dispatch to the backend driver.
_svc_drive() {
    local verb="$1" kind="$2" scope="$3" target="$4"
    if ! _svc_known_kind "$kind"; then
        printf 'mesh services: unknown backend kind: %s\n' "$kind" >&2
        return 2
    fi
    "svc_${kind}_${verb}" "$scope" "$target"
}

svc_status()    { _svc_drive status    "$@"; }
svc_installed() { _svc_drive installed "$@"; }
svc_start()     { _svc_drive start     "$@"; }
svc_stop()      { _svc_drive stop      "$@"; }
svc_restart()   { _svc_drive restart   "$@"; }
svc_enable()    { _svc_drive enable    "$@"; }
svc_disable()   { _svc_drive disable   "$@"; }

# svc_orthogonal <kind> — rc 0 if the backend sets active/enabled independently.
svc_orthogonal() {
    _svc_known_kind "$1" || return 2
    "svc_$1_orthogonal"
}

# svc_collateral <kind> <verb> — print the unrequested bit the verb ALSO mutates
# on this backend (empty if none). Orthogonal backends never have collateral.
# brew: enable/disable also flip active; stop also flips enabled; start/restart
# are active-only (`brew services run` does NOT register login autostart).
svc_collateral() {
    local kind="$1" verb="$2"
    _svc_known_kind "$kind" || return 2
    if "svc_${kind}_orthogonal"; then
        return 0
    fi
    case "$kind" in
        brew)
            case "$verb" in
                enable|disable) printf 'active' ;;
                stop)           printf 'enabled' ;;
                start|restart)  printf '' ;;
            esac
            ;;
    esac
}
