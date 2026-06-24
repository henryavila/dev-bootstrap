#!/usr/bin/env bash
# scripts/runners/upgrade.sh — `mesh upgrade`: on-demand, version-aware upgrade of
# mesh-managed packages.
#
# Runs the engine's --update pass over the saved selection NOW, bypassing the
# daily login throttle (MESH_UPDATE_FORCE=1). It upgrades only:
#   - items marked `autoupdate: true` in the manifest (the per-item override), and
#   - items whose topic category is opted in (MESH_UPDATE_AGENT_CLIS / _CLI_TOOLS /
#     _RUNTIMES_DBS), if any.
# Each upgrade is version-aware via the package manager's native `outdated` query
# — never a blind reinstall, never `brew upgrade` of the whole world, never an
# unflagged package. New (not-yet-installed) items are never installed here.
#
# Usage:
#   mesh upgrade            apply available upgrades to flagged/opted items
#   mesh upgrade --dry-run  list what would be checked/upgraded; change nothing
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_DIR="$(cd "$HERE/../.." && pwd)"

DRY_RUN=0
while (($#)); do
    case "$1" in
        -n|--dry-run) DRY_RUN=1 ;;
        -h|--help)
            sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            printf 'mesh upgrade: unknown argument %s (try --dry-run or --help)\n' "$1" >&2
            exit 64 ;;
    esac
    shift
done

sel="${XDG_CONFIG_HOME:-$HOME/.config}/mesh/selections.list"
if [[ ! -r "$sel" ]]; then
    printf 'mesh upgrade: no selections.list at %s — run `mesh setup` first\n' "$sel" >&2
    exit 1
fi
engine="$WS_DIR/scripts/lib/install-engine.sh"
if [[ ! -r "$engine" ]]; then
    printf 'mesh upgrade: install-engine not found at %s\n' "$engine" >&2
    exit 1
fi

args=(--update --non-interactive --selections "$sel")
((DRY_RUN)) && args+=(--dry-run)

# Calling the engine directly already bypasses the daily throttle (that lives in
# auto-update.sh's login pass, not the engine). Export MESH_UPDATE_FORCE too so
# the intent holds for any future auto-update-routed path.
export MESH_UPDATE_FORCE=1
exec bash "$engine" "${args[@]}"
