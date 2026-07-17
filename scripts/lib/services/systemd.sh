# shellcheck shell=bash
# scripts/lib/services/systemd.sh — systemd backend for `mesh services`.
#
# Implements svc_systemd_<verb> over a descriptor's `scope target`
# (scope ∈ system|user; target = the unit name). Two orthogonal bits map 1:1
# onto systemd, so svc_systemd_orthogonal returns 0:
#   active  — is-active   / start | stop | restart   (runtime)
#   enabled — is-enabled  / enable | disable          (boot/login autostart)
#
# Privilege:
#   system scope → mutations via `sudo systemctl`; READS never use sudo.
#   user   scope → `systemctl --user` (never sudo); `enable` also ensures
#                  loginctl linger so the unit autostarts at boot, not just at
#                  login (mirrors scripts/lib/user-service.sh).
#
# Sourced by driver.sh; do not execute directly. No `set -e` (sourced lib).

# _svc_sd_read <scope> <args...> — systemctl read; never sudo.
_svc_sd_read() {
    local scope="$1"; shift
    if [[ "$scope" == user ]]; then
        systemctl --user "$@"
    else
        systemctl "$@"
    fi
}

# _svc_sd_mutate <scope> <args...> — systemctl mutation; sudo for system scope.
_svc_sd_mutate() {
    local scope="$1"; shift
    if [[ "$scope" == user ]]; then
        systemctl --user "$@"
    else
        sudo systemctl "$@"
    fi
}

# _svc_sd_ensure_linger — make user units autostart at boot, not just at login.
# Mirrors scripts/lib/user-service.sh; best-effort, never fatal.
_svc_sd_ensure_linger() {
    command -v loginctl >/dev/null 2>&1 || return 0
    if ! loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
        sudo loginctl enable-linger "$USER" 2>/dev/null || true
    fi
}

svc_systemd_orthogonal() { return 0; }

svc_systemd_installed() {
    local scope="$1" unit="$2" service_unit
    service_unit="$unit"
    [[ "$service_unit" == *.service ]] || service_unit="${service_unit}.service"
    _svc_sd_read "$scope" list-unit-files --type=service --no-legend 2>/dev/null \
        | awk -v unit="$unit" -v service_unit="$service_unit" '
            $1 == unit || $1 == service_unit { found=1 }
            END { exit(found ? 0 : 1) }
        '
}

svc_systemd_status() {
    local scope="$1" unit="$2" a e active enabled
    a="$(_svc_sd_read "$scope" is-active "$unit" 2>/dev/null)"
    e="$(_svc_sd_read "$scope" is-enabled "$unit" 2>/dev/null)"
    case "$a" in
        active) active=on ;;
        *)      active=off ;;
    esac
    case "$e" in
        enabled|enabled-runtime) enabled=on ;;
        disabled)                enabled=off ;;
        *)                       enabled=unknown ;;
    esac
    printf 'active=%s\nenabled=%s\northogonal=yes\n' "$active" "$enabled"
}

svc_systemd_start()   { _svc_sd_mutate "$1" start   "$2"; }
svc_systemd_stop()    { _svc_sd_mutate "$1" stop    "$2"; }
svc_systemd_restart() { _svc_sd_mutate "$1" restart "$2"; }
svc_systemd_disable() { _svc_sd_mutate "$1" disable "$2"; }

svc_systemd_enable() {
    [[ "$1" == user ]] && _svc_sd_ensure_linger
    _svc_sd_mutate "$1" enable "$2"
}
