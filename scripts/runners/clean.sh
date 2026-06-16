#!/usr/bin/env bash
# scripts/runners/clean.sh — `mesh clean`: OS-aware disk reclaim.
#
# Phase A (this script, any OS): purge regenerable dev caches via a registry of
#   modular cleaners (scripts/lib/cleaners/*.sh). DRY-RUN by default.
# Phase B (--compact, WSL only): hand off the VHDX compaction (wsl --set-sparse)
#   that returns freed space to the Windows host. It must run from Windows (you
#   cannot shut the distro down from inside it), so this prints the exact
#   command and points at windows/wsl-compact.ps1.
#
# Usage:
#   mesh clean                 Dry-run: list reclaimable caches, delete nothing.
#   mesh clean --apply         Purge Tier-1 caches (regenerable, no re-download).
#   mesh clean --apply --deep  Also purge Tier-2 (browser/model caches; re-download).
#   mesh clean --compact       WSL: print the VHDX set-sparse compaction step.
#   mesh clean --apply --deep --compact   Full reclaim + compaction handoff.
# Flags: --yes/-y (skip the apply confirmation), -h/--help.
#
# Env: MESH_CLEAN_OS overrides detect-os (tests / forks); MESH_CLEANERS_DIR
#      overrides the cleaner module directory.
#
# No `set -e`: one cleaner failing must not abort the sweep — each is guarded and
# we accumulate. `set -uo pipefail` catches the rest.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CLEANERS_DIR="${MESH_CLEANERS_DIR:-$REPO/scripts/lib/cleaners}"
# shellcheck disable=SC1091
. "$REPO/scripts/lib/log.sh"
# shellcheck disable=SC1091
. "$CLEANERS_DIR/_lib.sh"

CLEAN_OS="${MESH_CLEAN_OS:-$(bash "$REPO/scripts/lib/detect-os.sh" 2>/dev/null || echo unknown)}"

APPLY=0; DEEP=0; YES=0; COMPACT=0
while (( $# > 0 )); do
    case "$1" in
        --apply)   APPLY=1 ;;
        --deep)    DEEP=1 ;;
        --yes|-y)  YES=1 ;;
        --compact) COMPACT=1 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) log_error "clean: unknown flag '$1' (try --apply --deep --compact --yes)"; exit 2 ;;
    esac
    shift
done

# Discover + source cleaner modules. Cleaner name = filename without .sh; files
# starting with `_` (e.g. _lib.sh) are private helpers, not cleaners.
CLEANER_NAMES=()
for f in "$CLEANERS_DIR"/*.sh; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f" .sh)"
    [[ "$base" == _* ]] && continue
    # shellcheck disable=SC1090
    . "$f"
    CLEANER_NAMES+=("$base")
done

TOTAL=0
# process <measure|clean> — iterate applicable cleaners of the selected tiers,
# print one row each, accumulate TOTAL (bytes).
process() {
    local mode="$1" n tier desc bytes tag
    TOTAL=0
    for n in "${CLEANER_NAMES[@]+"${CLEANER_NAMES[@]}"}"; do
        "cleaner_${n}_applies" || continue
        tier="$("cleaner_${n}_tier")"
        # Tier-2 is opt-in for real deletion; dry-run still shows it (annotated).
        if [[ "$tier" == 2 && "$DEEP" == 0 && "$mode" == clean ]]; then
            continue
        fi
        desc="$("cleaner_${n}_desc")"
        if [[ "$mode" == clean ]]; then
            bytes="$("cleaner_${n}_clean")"
        else
            bytes="$("cleaner_${n}_measure")"
        fi
        [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
        TOTAL=$(( TOTAL + bytes ))
        tag=""
        [[ "$tier" == 2 ]] && tag="  [--deep]"
        printf '  %-12s %9s  %s%s\n' "$n" "$(clean_human "$bytes")" "$desc" "$tag"
    done
}

# do_compact — WSL VHDX compaction handoff (Phase B). No-op off-WSL.
do_compact() {
    if [[ "$CLEAN_OS" != wsl ]]; then
        info "VHDX compaction is WSL-only — this is '${CLEAN_OS}', nothing to compact."
        return 0
    fi
    local distro="${WSL_DISTRO_NAME:-Ubuntu}"
    local ps1="$REPO/windows/wsl-compact.ps1"
    banner "WSL VHDX compaction (Phase B — run from Windows)"
    cat <<EOF
The ext4.vhdx grows but never shrinks on its own: deleting caches inside WSL
does NOT return space to C: until the disk is compacted, and that must run from
Windows (you cannot shut the distro down from within it).

Run this in a Windows PowerShell (no admin needed on WSL 2.x):

    wsl --shutdown
    wsl --manage ${distro} --set-sparse true

--set-sparse compacts now AND makes the disk auto-shrink from here on.
EOF
    if [[ -f "$ps1" ]]; then
        printf '\n'
        info "Or run the bundled script from Windows:"
        info "  powershell -ExecutionPolicy Bypass -File <windows>\\wsl-compact.ps1 -Distro ${distro}"
        info "  (repo copy: ${ps1})"
    fi
    return 0
}

banner "mesh clean — disk reclaim (${CLEAN_OS})"

if (( APPLY )); then
    if (( YES == 0 )); then
        if [[ "${NON_INTERACTIVE:-0}" == 1 || ! -e /dev/tty ]]; then
            log_error "clean: --apply needs confirmation — re-run with --yes (non-interactive) or from a terminal."
            exit 3
        fi
        prompt="Delete regenerable caches now?"
        (( DEEP )) && prompt="Delete regenerable caches now, including --deep heavy caches?"
        if ! confirm "$prompt" n; then
            info "Aborted — nothing deleted."
            exit 0
        fi
    fi
    info "Reclaiming…"
    process clean
    printf '\n'
    ok "Total freed: $(clean_human "$TOTAL")"
    # On WSL, freeing caches shrinks usage INSIDE the distro but the ext4.vhdx on
    # the Windows host is grow-only — the space is not back on C: until it is
    # compacted (Phase B). Nudge toward --compact unless it was already requested.
    if [[ "$CLEAN_OS" == wsl && "$COMPACT" == 0 ]]; then
        printf '\n'
        warn "Freed inside WSL — but the ext4.vhdx is grow-only; that space is NOT back on C: yet."
        info "Phase B: run  mesh clean --compact  for the Windows-side step that shrinks the VHDX."
    fi
fi

if (( ! APPLY && ! COMPACT )); then
    process measure
    printf '\n'
    info "Total reclaimable: $(clean_human "$TOTAL")  (dry-run — nothing deleted; pass --apply to reclaim)"
fi

if (( COMPACT )); then
    do_compact
fi

exit 0
