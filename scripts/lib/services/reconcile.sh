# shellcheck shell=bash
# scripts/lib/services/reconcile.sh — boot-state reconciliation toward the
# per-host services.default.<alias> (T-006). The single shared primitive that
# BOTH the runner verb `mesh services reconcile` AND the topic installers call
# in place of an inline `systemctl enable --now` — so install is decoupled from
# auto-enable (G-3). Reconcile touches ONLY the enabled (boot) bit; it never
# starts or stops a running unit (codex F-004 — `disable` ≠ `stop`).
#
# services.default.<alias>: a newline declarative list (one service id per line,
# `#` comments + blank lines ignored — same contract as shell/*.list), naming the
# services that SHOULD be enabled at boot on this host. Anything opt-out and NOT
# listed is disabled at boot. A missing file ⇒ empty set ⇒ every opt-out daemon
# disabled (the safe default the resource audit wants).
#
# Env:
#   MESH_SERVICES_DEFAULT  full path to the services.default file (tests/override)
#   MESH_SERVICES_ALIAS    host alias (mac|ultron|crc); else MESH_HOST_ALIAS;
#                          else `hostname -s`. bin/mesh exports the resolved
#                          alias (_mesh_self_alias) before delegating.
#   MESH_IDENTITY_DIR      identity repo root (default $HOME/mesh-identity)
#
# Sourced; do not execute directly. No `set -e` (sourced lib; uses `:-` defaults
# so it is safe under a caller's `set -u`).

_RECON_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source the registry + driver only if the caller has not already (the runner
# has; a topic installer sourcing this fresh has not).
declare -F services_registry_resolve >/dev/null 2>&1 || . "$_RECON_HERE/registry.sh"
declare -F svc_status >/dev/null 2>&1 || . "$_RECON_HERE/driver.sh"

# services_default_path — resolve the per-host services.default file path.
services_default_path() {
    if [[ -n "${MESH_SERVICES_DEFAULT:-}" ]]; then
        printf '%s' "$MESH_SERVICES_DEFAULT"
        return 0
    fi
    local host_alias="${MESH_SERVICES_ALIAS:-${MESH_HOST_ALIAS:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)}}"
    printf '%s' "${MESH_IDENTITY_DIR:-$HOME/mesh-identity}/config/services.default.${host_alias}"
}

# services_default_read — print the desired-enabled ids (one per line). Strips
# `#` comments + leading/trailing whitespace + blank lines (same parse as
# personal-clone.sh `_read_catalog`). Empty output when the file is absent.
services_default_read() {
    local file line
    file="$(services_default_path)"
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        printf '%s\n' "$line"
    done <"$file"
}

# services_default_has <id> — rc0 if <id> is opted in to boot. An enumerated id
# (base@inst, e.g. php-fpm@8.2 / postgres@16-main) matches an entry for its base
# (php-fpm / postgres) too — so one `php-fpm` line opts in every installed
# version, while a specific `php-fpm@8.2` line opts in just that one.
services_default_has() {
    local id="$1" base="${1%@*}" want
    while IFS= read -r want; do
        [[ "$want" == "$id" || "$want" == "$base" ]] && return 0
    done < <(services_default_read)
    return 1
}

# _recon_enabled_now <kind> <scope> <target> — print the current boot bit
# (on|off|unknown) read via the driver's svc_status (a read; never sudo).
_recon_enabled_now() {
    svc_status "$1" "$2" "$3" 2>/dev/null | sed -n 's/^enabled=//p' | head -n1
}

# services_reconcile_one <id> — apply boot-state for one logical service (and its
# enumerated instances) toward services.default: enable when opted-in, disable
# otherwise — but ONLY when the current boot bit differs, so a re-run is a no-op
# (idempotent). Enabled bit only; never start/stop. Prints a per-row result line.
# rc0 unless an enable/disable command fails; rc1 if <id> matches no curated row.
services_reconcile_one() {
    local id="$1" rows rid rdisp ral rown rkind rscope rtarget
    local desired current rc=0 acted=0
    rows="$(services_registry_resolve)"
    while IFS='|' read -r rid rdisp ral rown rkind rscope rtarget; do
        [[ -n "$rid" ]] || continue
        [[ "$rid" == "$id" || "$rid" == "$id"@* ]] || continue
        acted=1
        if services_default_has "$rid"; then desired=on; else desired=off; fi
        current="$(_recon_enabled_now "$rkind" "$rscope" "$rtarget")"
        if [[ "$desired" == on && "$current" != on ]]; then
            if svc_enable "$rkind" "$rscope" "$rtarget" >/dev/null 2>&1; then
                printf 'reconcile: %s → enabled at boot\n' "$rid"
            else printf 'reconcile: %s → enable FAILED\n' "$rid" >&2; rc=1; fi
        elif [[ "$desired" == off && "$current" != off ]]; then
            if svc_disable "$rkind" "$rscope" "$rtarget" >/dev/null 2>&1; then
                printf 'reconcile: %s → disabled at boot\n' "$rid"
            else printf 'reconcile: %s → disable FAILED\n' "$rid" >&2; rc=1; fi
        else
            printf 'reconcile: %s already %s at boot — no change\n' "$rid" "$desired"
        fi
    done <<<"$rows"
    if (( ! acted )); then
        printf 'reconcile: %s — no such curated service for %s\n' "$id" "${SERVICES_OS:-?}" >&2
        return 1
    fi
    return "$rc"
}
