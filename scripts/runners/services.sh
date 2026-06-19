#!/usr/bin/env bash
# scripts/runners/services.sh — `mesh services`: cross-platform service control.
#
# Controls the runtime state of mesh-owned daemons across platforms (systemd on
# WSL/Linux, brew services / launchd on mac) through ONE set of verbs, over the
# two orthogonal bits every service has: active (running now) × enabled (boot).
#
# Usage:
#   mesh services list [--porcelain] [--all]  List services with active+enabled badges.
#                                      --all also shows discovered (non-curated) units, read-only.
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

# _svc_is_discovered <query> — rc0 if the name matches a `--all`-discovered unit
# that is NOT in the curated registry. Lets cmd_action turn a bare no-match into a
# precise "only curated services are mutable" refusal (T-005: discovered entries
# have no descriptor, so they are list/status-only).
_svc_is_discovered() {
    local q="$1" discovered
    discovered="$(services_discover_all 2>/dev/null)" || return 1
    [[ -n "$discovered" ]] || return 1
    printf '%s\n' "$discovered" \
        | awk -F'|' -v q="$q" 'BEGIN{f=1} $1!="" && ($1==q || index($1,q)){f=0} END{exit f}'
}

# ─── Verbs ───────────────────────────────────────────────────────────────────

# _emit_row <porcelain> <id> <display> <aliases> <owner> <kind> <scope> <target>
# Read the live two bits via the driver and print the human or porcelain row.
_emit_row() {
    local porcelain="$1"; shift
    local id="$1" display="$2" aliases="$3" owner="$4" kind="$5" scope="$6" target="$7"
    _parse_state < <(svc_status "$kind" "$scope" "$target")
    if (( porcelain )); then
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$id" "$display" "$aliases" "$owner" "$kind" "$scope" "$target" "$ACT" "$ENA"
    else
        printf '  %-14s %-9s %-9s %-9s %s\n' \
            "$id" "$(_badge_active "$ACT")" "$(_badge_enabled "$ENA")" "$kind" "$owner"
    fi
}

# _list_discovered <curated_rows> <porcelain> — the `--all` discovery block: every
# unit BEYOND the curated registry, READ-ONLY, deduped against curated ids. These
# carry no descriptor, so cmd_action refuses to mutate them (see _svc_is_discovered).
_list_discovered() {
    local curated_rows="$1" porcelain="$2"
    local curated_ids discovered shown=0
    curated_ids="$(printf '%s\n' "$curated_rows" | awk -F'|' 'NF{print $1}')"
    discovered="$(services_discover_all)"
    [[ -n "$discovered" ]] || return 0
    local id display aliases owner kind scope target
    while IFS='|' read -r id display aliases owner kind scope target; do
        [[ -n "$id" ]] || continue
        printf '%s\n' "$curated_ids" | grep -qxF "$id" && continue   # already curated
        if (( ! porcelain )) && (( ! shown )); then
            info "discovered (read-only — only the curated services above are mutable):"
            shown=1
        fi
        _emit_row "$porcelain" "$id" "$display" "$aliases" "$owner" "$kind" "$scope" "$target"
    done <<<"$discovered"
}

cmd_list() {
    local porcelain=0 all=0
    while (( $# > 0 )); do
        case "$1" in
            --porcelain|--plain) porcelain=1 ;;
            --all)               all=1 ;;
            *) log_error "services list: unknown flag '$1'"; return 2 ;;
        esac
        shift
    done
    local rows; rows="$(services_registry_resolve)"
    if [[ -z "$rows" ]] && (( ! all )); then
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
        _emit_row "$porcelain" "$id" "$display" "$aliases" "$owner" "$kind" "$scope" "$target"
    done <<<"$rows"
    (( all )) && _list_discovered "$rows" "$porcelain"
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
        if ! row="$(_resolve_one "$name")"; then
            if _svc_is_discovered "$name"; then
                log_error "services: '$name' is discovered but not curated — only curated services are mutable (add a descriptor under scripts/lib/services/registry/ to manage it)"
            fi
            rc=1; continue
        fi
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

# ─── Interactive (no-arg) flow ───────────────────────────────────────────────
# Blink picker (preferred): feed the porcelain rows, read `<id>\t<verb>` back.
# Exit codes mirror services-main so the caller tells cancel from unavailable:
#   0 → choice printed · 130 → Esc (cancel, do NOT fall back) · 1 → unavailable.
_svc_pick_blink() {
    local menu="$SVC_REPO/scripts/menu/index.js" rows="$1" infile out rc
    [[ "${MESH_SERVICES_PICKER:-}" == bash ]] && return 1
    command -v node >/dev/null 2>&1 || return 1
    [[ -f "$menu" ]] || return 1
    infile="$(mktemp -t mesh-svc-rows.XXXXXX)" || return 1
    out="$(mktemp -t mesh-svc-out.XXXXXX)" || { rm -f "$infile"; return 1; }
    printf '%s\n' "$rows" >"$infile"
    node "$menu" services --in "$infile" --out "$out" </dev/tty >/dev/tty 2>/dev/null
    rc=$?
    if (( rc == 0 )); then cat "$out"; rm -f "$infile" "$out"; return 0; fi
    rm -f "$infile" "$out"
    (( rc == 130 )) && return 130
    return 1
}

# Bash fallback picker: numbered service chooser → numbered context-aware action
# chooser, both on /dev/tty (used when blink is unavailable, or
# MESH_SERVICES_PICKER=bash). Prints the chosen `<id>\t<verb>`.
_svc_pick_bash() {
    local rows="$1" n=0 sel idx
    local f_id f_display f_aliases f_owner f_kind f_scope f_target f_active f_enabled
    local -a ids=() displays=() actives=() enableds=()
    while IFS='|' read -r f_id f_display f_aliases f_owner f_kind f_scope f_target f_active f_enabled; do
        [[ -n "$f_id" ]] || continue
        n=$((n + 1))
        ids+=("$f_id"); displays+=("$f_display"); actives+=("$f_active"); enableds+=("$f_enabled")
        printf '  %2d) %-14s %-9s %-9s %s\n' \
            "$n" "$f_display" "$(_badge_active "$f_active")" "$(_badge_enabled "$f_enabled")" "$f_kind" >&2
    done <<<"$rows"
    (( n > 0 )) || { log_error "services: nothing to control"; return 1; }
    printf 'services> pick a number (or q): ' >&2
    IFS= read -r sel </dev/tty || return 1
    [[ "$sel" == q || -z "$sel" ]] && return 1
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= n )) || { log_error "services: invalid choice"; return 1; }
    idx=$((sel - 1))
    # Context-aware verbs for the chosen service's two bits (mirrors actionsFor).
    local -a verbs=()
    case "${actives[$idx]}" in on) verbs+=(stop restart) ;; off) verbs+=(start) ;; *) verbs+=(start stop restart) ;; esac
    case "${enableds[$idx]}" in on) verbs+=(disable) ;; off) verbs+=(enable) ;; *) verbs+=(enable disable) ;; esac
    local i=0 v
    for v in "${verbs[@]}"; do i=$((i + 1)); printf '  %2d) %s\n' "$i" "$v" >&2; done
    printf 'services> action for %s (or q): ' "${displays[$idx]}" >&2
    IFS= read -r sel </dev/tty || return 1
    [[ "$sel" == q || -z "$sel" ]] && return 1
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#verbs[@]} )) || { log_error "services: invalid choice"; return 1; }
    printf '%s\t%s' "${ids[$idx]}" "${verbs[$((sel - 1))]}"
}

# cmd_interactive — the no-arg flow: list → pick a service → pick an action →
# run it. Non-interactive contexts (NON_INTERACTIVE=1 or no /dev/tty) print the
# usage instead of launching, so `mesh services` never hangs in CI/scripts.
cmd_interactive() {
    if [[ "${NON_INTERACTIVE:-0}" == 1 || ! -e /dev/tty ]]; then
        usage
        return 0
    fi
    local rows choice id verb rc
    rows="$(cmd_list --porcelain)"
    if [[ -z "$rows" ]]; then
        info "No mesh-owned services for this platform (${SERVICES_OS})."
        return 0
    fi
    choice="$(_svc_pick_blink "$rows")"; rc=$?
    if (( rc == 130 )); then return 0; fi              # Esc → cancel
    if (( rc != 0 )); then choice="$(_svc_pick_bash "$rows")" || return 0; fi
    [[ -n "$choice" ]] || return 0
    IFS=$'\t' read -r id verb <<<"$choice"
    [[ -n "$id" && -n "$verb" ]] || return 0
    cmd_action "$verb" "$id"
}

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; }

verb="${1:-}"
[[ $# -gt 0 ]] && shift
case "$verb" in
    list)                                cmd_list "$@" ;;
    status)                              cmd_status "$@" ;;
    start|stop|restart|enable|disable)   cmd_action "$verb" "$@" ;;
    -h|--help)                           usage; exit 0 ;;
    "")                                  cmd_interactive ;;
    *) log_error "services: unknown verb '$verb' (try list|status|start|stop|restart|enable|disable)"; exit 2 ;;
esac
