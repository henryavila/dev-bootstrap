# shellcheck shell=bash
# scripts/lib/services/launchd.sh — launchd backend for non-brew mac daemons.
#
# launchd separates the two bits (enable/disable persist a label across logins;
# kickstart/stop are runtime), so svc_launchd_orthogonal returns 0. Operates in
# the per-user GUI domain (gui/<uid>). Descriptor scope is empty; target = the
# launchd label (e.g. com.example.daemon). Sourced; no set -e.

_svc_launchd_domain() { printf 'gui/%s' "$(id -u)"; }

svc_launchd_orthogonal() { return 0; }

svc_launchd_status() {
    local label="$2" out active enabled
    if out="$(launchctl list "$label" 2>/dev/null)"; then
        enabled=on
        if printf '%s' "$out" | grep -qE '"PID"[[:space:]]*=[[:space:]]*[0-9]+'; then
            active=on
        else
            active=off
        fi
    else
        active=off
        enabled=off
    fi
    printf 'active=%s\nenabled=%s\northogonal=yes\n' "$active" "$enabled"
}

svc_launchd_start()   { launchctl kickstart    "$(_svc_launchd_domain)/$2"; }
svc_launchd_restart() { launchctl kickstart -k "$(_svc_launchd_domain)/$2"; }
svc_launchd_stop()    { launchctl stop "$2"; }
svc_launchd_enable()  { launchctl enable  "$(_svc_launchd_domain)/$2"; }
svc_launchd_disable() { launchctl disable "$(_svc_launchd_domain)/$2"; }
