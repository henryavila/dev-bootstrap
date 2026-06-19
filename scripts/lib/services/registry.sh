#!/usr/bin/env bash
# scripts/lib/services/registry.sh — `mesh services` registry aggregator.
#
# The registry is a set of bash DESCRIPTOR MODULES under registry/<id>.sh (one
# per logical service, mirroring scripts/lib/cleaners/). This file walks them,
# resolves each for the current OS, and emits one machine-readable row per
# applicable service:
#
#     id|display|aliases|owner|kind|scope|target
#
# Consumed by the runner (`mesh services list`) and the blink TUI (which reads
# THIS output, not the modules) — so the row format is the stable contract.
#
# A descriptor module registry/<id>.sh declares (the id is the basename; in
# function names hyphens become underscores):
#   svcdef_<id>_meta   → `display|aliases|owner`   (REQUIRED; aliases CSV, may be empty)
#   svcdef_<id>_<os>   → `kind|scope|target`       (per OS: wsl | mac | linux)
#                          systemd → systemd|system|<unit>   or  systemd|user|<unit>
#                          brew    → brew||<formula>
#                          launchd → launchd||<label>
#   svcdef_<id>_optout → per-OS opt-out tokens      (OPTIONAL; T-006)
#   svcdef_<id>_enumerate → dynamic expansion hook  (OPTIONAL; T-005, e.g. php)
# linux falls back to the wsl (systemd) mapping when no svcdef_<id>_linux exists
# (the systemd backend is a Linux capability, not WSL-only — see audience note).
#
# Env: MESH_SERVICES_OS overrides detect-os (tests/forks; mirrors MESH_CLEAN_OS);
#      MESH_SERVICES_REGISTRY_DIR overrides the descriptor dir (mirrors
#      MESH_CLEANERS_DIR).
#
# No `set -e`: one malformed descriptor must not abort resolution — we warn and
# skip it. `set -uo pipefail` catches the rest.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
SERVICES_REGISTRY_DIR="${MESH_SERVICES_REGISTRY_DIR:-$HERE/registry}"
SERVICES_OS="${MESH_SERVICES_OS:-$(bash "$REPO/scripts/lib/detect-os.sh" 2>/dev/null || echo unknown)}"

_svc_warn() { printf 'mesh services: registry: %s\n' "$*" >&2; }

# _svc_fn_id <id> — sanitise an id into a bash-function-safe token (hyphens→_).
_svc_fn_id() { printf '%s' "$1" | tr '-' '_'; }

# _svc_os_mapping <fn_id> <os> — print the `kind|scope|target` triple for the OS
# (rc0), or nothing (rc1) when the service has no descriptor for it. linux reuses
# the wsl/systemd mapping when no dedicated svcdef_<id>_linux is defined.
_svc_os_mapping() {
    local fid="$1" os="$2"
    if declare -f "svcdef_${fid}_${os}" >/dev/null 2>&1; then
        "svcdef_${fid}_${os}"
        return 0
    fi
    if [[ "$os" == linux ]] && declare -f "svcdef_${fid}_wsl" >/dev/null 2>&1; then
        "svcdef_${fid}_wsl"
        return 0
    fi
    return 1
}

# services_registry_resolve — emit one row per service applicable on SERVICES_OS.
# Skips `_`-prefixed files (private helpers) and modules missing the required
# meta function; omits services with no descriptor for the current OS.
services_registry_resolve() {
    local dir="$SERVICES_REGISTRY_DIR"
    local f base id fid meta display aliases owner mapping kind scope target
    local enum inst_id inst_display inst_target emitted
    if [[ ! -d "$dir" ]]; then
        _svc_warn "descriptor dir not found: $dir"
        return 0
    fi
    for f in "$dir"/*.sh; do
        [[ -e "$f" ]] || continue
        base="$(basename "$f" .sh)"
        [[ "$base" == _* ]] && continue
        # shellcheck disable=SC1090
        . "$f"
        id="$base"
        fid="$(_svc_fn_id "$id")"
        if ! declare -f "svcdef_${fid}_meta" >/dev/null 2>&1; then
            _svc_warn "module '$id' has no svcdef_${fid}_meta — skipped"
            continue
        fi
        meta="$("svcdef_${fid}_meta")"
        IFS='|' read -r display aliases owner <<<"$meta"
        mapping="$(_svc_os_mapping "$fid" "$SERVICES_OS")" || continue
        [[ -n "$mapping" ]] || continue
        IFS='|' read -r kind scope target <<<"$mapping"
        # Dynamic enumeration (T-005): a module may expand into one instance row
        # per discovered version (e.g. php-fpm@8.2…), reusing the shared
        # aliases/owner/kind/scope; the hook supplies per-instance id|display|
        # target. Empty hook output ⇒ fall through to the static single row.
        if declare -f "svcdef_${fid}_enumerate" >/dev/null 2>&1; then
            enum="$("svcdef_${fid}_enumerate" "$SERVICES_OS")"
            emitted=0
            while IFS='|' read -r inst_id inst_display inst_target; do
                [[ -n "$inst_id" ]] || continue
                printf '%s|%s|%s|%s|%s|%s|%s\n' \
                    "$inst_id" "$inst_display" "$aliases" "$owner" "$kind" "$scope" "$inst_target"
                emitted=1
            done <<<"$enum"
            (( emitted )) && continue
        fi
        printf '%s|%s|%s|%s|%s|%s|%s\n' \
            "$id" "$display" "$aliases" "$owner" "$kind" "$scope" "$target"
    done
}

# services_discover_all — emit a row per unit on SERVICES_OS BEYOND the curated
# registry, in the SAME 7-field format with owner=discovered. Read-only surface
# for `mesh services list --all` (T-005): discovered entries carry no normalised
# descriptor, so the runner REFUSES mutating verbs on them — only curated
# services (a descriptor module under registry/) are mutable. Skips systemd
# template units (name ends in @). OS access is stub-friendly (systemctl / brew /
# launchctl), mirroring the driver + the test PATH-shim.
services_discover_all() {
    local name label
    case "$SERVICES_OS" in
        wsl|linux)
            systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null \
                | awk '{print $1}' \
                | while IFS= read -r name; do
                    name="${name%.service}"
                    [[ -n "$name" && "$name" != *@ ]] || continue
                    printf '%s|%s||discovered|systemd|system|%s\n' "$name" "$name" "$name"
                done
            ;;
        mac)
            brew services list 2>/dev/null | awk 'NR>1 {print $1}' \
                | while IFS= read -r name; do
                    [[ -n "$name" ]] || continue
                    printf '%s|%s||discovered|brew||%s\n' "$name" "$name" "$name"
                done
            launchctl list 2>/dev/null | awk 'NR>1 {print $3}' \
                | while IFS= read -r label; do
                    [[ -n "$label" && "$label" != "-" ]] || continue
                    printf '%s|%s||discovered|launchd||%s\n' "$label" "$label" "$label"
                done
            ;;
    esac
}

# Run directly → print the resolved registry. Sourced → only define functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    services_registry_resolve
fi
