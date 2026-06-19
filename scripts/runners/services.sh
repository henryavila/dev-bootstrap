#!/usr/bin/env bash
# scripts/runners/services.sh — `mesh services`: cross-platform service control.
#
# Controls the runtime state of mesh-owned daemons across platforms (systemd on
# WSL/Linux, brew services / launchd on mac) through ONE set of verbs, over the
# two orthogonal bits every service has: active (running now) × enabled (boot).
#
# Usage:
#   mesh services list [--porcelain]   List curated services with active+enabled badges.
#   mesh services status <name>        Show one service's two bits + backend model.
#   mesh services start   <name>...    Start (active) one or more services.
#   mesh services stop    <name>...    Stop (active) one or more services.
#   mesh services restart <name>...    Restart one or more services.
#   mesh services enable  <name>...    Enable at boot (enabled) one or more services.
#   mesh services disable <name>...    Disable at boot one or more services.
# Names match a service by exact id, else substring of its id or aliases.
# Multiple verbs exit non-zero if ANY service fails; an unknown name is a clear error.
# A non-orthogonal backend (brew) warns when a verb also flips the other bit —
# it never mutates the unrequested bit silently.
#
# Env: MESH_SERVICES_OS overrides detect-os (tests/forks); MESH_SERVICES_REGISTRY_DIR
#      overrides the descriptor dir. The interactive no-arg flow is T-004 (blink-tui).
#
# No `set -e`: one service failing must not abort a multi-service verb — we
# accumulate per-service results and a single aggregate exit code.
set -uo pipefail

SVC_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SVC_REPO="$(cd "$SVC_HERE/../.." && pwd)"
# shellcheck disable=SC1091
. "$SVC_REPO/scripts/lib/log.sh"
# shellcheck disable=SC1091
. "$SVC_REPO/scripts/lib/services/registry.sh"   # services_registry_resolve + SERVICES_OS
# shellcheck disable=SC1091
. "$SVC_REPO/scripts/lib/services/driver.sh"      # svc_status/start/… + svc_orthogonal/svc_collateral

# ─── State badges (human view) ───────────────────────────────────────────────
_badge_active()  { case "$1" in on) printf 'running' ;; off) printf 'stopped' ;; *) printf '?' ;; esac; }
_badge_enabled() { case "$1" in on) printf 'on-boot' ;; off) printf 'no-boot' ;; *) printf '?' ;; esac; }

# _parse_state <svc_status output> via stdin — sets ACT/ENA/ORTH globals.
_parse_state() {
    ACT=""; ENA=""; ORTH=""
    local k v
    while IFS='=' read -r k v; do
        case "$k" in active) ACT="$v" ;; enabled) ENA="$v" ;; orthogonal) ORTH="$v" ;; esac
    done
}

# _resolve_one <query> — print the single matching registry row (rc0), or fail:
# rc1 = no match (logged), rc2 = ambiguous (logged with candidates). Exact id
# match wins; otherwise substring of id (field 1) or aliases CSV (field 3).
_resolve_one() {
    local q="$1" rows exact subs count
    rows="$(services_registry_resolve)"
    exact="$(printf '%s\n' "$rows" | awk -F'|' -v q="$q" '$1==q {print; exit}')"
    if [[ -n "$exact" ]]; then printf '%s\n' "$exact"; return 0; fi
    subs="$(printf '%s\n' "$rows" | awk -F'|' -v q="$q" '($1!="" && (index($1,q) || index($3,q))) {print}')"
    count="$(printf '%s' "$subs" | grep -c . || true)"
    if [[ "$count" -eq 0 ]]; then
        log_error "services: no service matches '$q' — see 'mesh services list'"
        return 1
    elif [[ "$count" -gt 1 ]]; then
        log_error "services: '$q' is ambiguous — matches: $(printf '%s' "$subs" | awk -F'|' '{printf "%s ", $1}')"
        return 2
    fi
    printf '%s\n' "$subs"
}

# ─── Verbs ───────────────────────────────────────────────────────────────────

cmd_list() {
    local porcelain=0
    case "${1:-}" in --porcelain|--plain) porcelain=1 ;; "") : ;; *) log_error "services list: unknown flag '$1'"; return 2 ;; esac
    local rows; rows="$(services_registry_resolve)"
    if [[ -z "$rows" ]]; then
        info "No mesh-owned services for this platform (${SERVICES_OS})."
        return 0
    fi
    if (( ! porcelain )); then
        banner "mesh services (${SERVICES_OS})"
        printf '  %-14s %-9s %-9s %-9s %s\n' SERVICE ACTIVE ENABLED BACKEND OWNER
    fi
    local id display aliases owner kind scope target
    while IFS='|' read -r id display aliases owner kind scope target; do
        [[ -n "$id" ]] || continue
        _parse_state < <(svc_status "$kind" "$scope" "$target")
        if (( porcelain )); then
            printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
                "$id" "$display" "$aliases" "$owner" "$kind" "$scope" "$target" "$ACT" "$ENA"
        else
            printf '  %-14s %-9s %-9s %-9s %s\n' \
                "$id" "$(_badge_active "$ACT")" "$(_badge_enabled "$ENA")" "$kind" "$owner"
        fi
    done <<<"$rows"
}

cmd_status() {
    [[ $# -gt 0 ]] || { log_error "services status: needs a service name"; return 2; }
    local row id display aliases owner kind scope target
    row="$(_resolve_one "$1")" || return 1
    IFS='|' read -r id display aliases owner kind scope target <<<"$row"
    _parse_state < <(svc_status "$kind" "$scope" "$target")
    banner "$display ($id)"
    info "backend : ${kind}${scope:+/$scope} → ${target}"
    info "active  : $(_badge_active "$ACT")"
    info "enabled : $(_badge_enabled "$ENA")"
    [[ "$ORTH" == no ]] && warn "${kind} couples active+enabled (non-orthogonal): start/enable/stop affect BOTH bits."
    info "owner   : ${owner}"
}

# cmd_action <verb> <name>... — run a mutating verb over one or more services.
# Aggregate rc: non-zero if any service fails or any name does not resolve.
cmd_action() {
    local verb="$1"; shift
    [[ $# -gt 0 ]] || { log_error "services ${verb}: needs at least one service name"; return 2; }
    local rc=0 name row id display aliases owner kind scope target collateral
    for name in "$@"; do
        if ! row="$(_resolve_one "$name")"; then rc=1; continue; fi
        IFS='|' read -r id display aliases owner kind scope target <<<"$row"
        # Never silently mutate the unrequested bit on a non-orthogonal backend.
        collateral="$(svc_collateral "$kind" "$verb")"
        [[ -n "$collateral" ]] && \
            warn "${display} (${kind}): '${verb}' also changes '${collateral}' — ${kind} couples the two bits; applying both."
        if "svc_${verb}" "$kind" "$scope" "$target"; then
            ok "${display}: ${verb}"
        else
            fail "${display}: ${verb} failed (rc $?)"
            rc=1
        fi
    done
    return "$rc"
}

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; }

verb="${1:-}"
[[ $# -gt 0 ]] && shift
case "$verb" in
    list)                                cmd_list "$@" ;;
    status)                              cmd_status "$@" ;;
    start|stop|restart|enable|disable)   cmd_action "$verb" "$@" ;;
    ""|-h|--help)                        usage; exit 0 ;;
    *) log_error "services: unknown verb '$verb' (try list|status|start|stop|restart|enable|disable)"; exit 2 ;;
esac
