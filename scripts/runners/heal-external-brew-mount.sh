#!/usr/bin/env bash
# heal-external-brew-mount.sh — corrective recovery for the macOS external-brew
# mount-disambiguation failure (see scripts/lib/external-brew-mount.sh).
#
# Invoked by `mesh doctor --fix`. Safe to run at any time and on any platform:
# a clean no-op unless an actual collision is present on macOS.
#
# Usage:
#   bash scripts/runners/heal-external-brew-mount.sh            heal (default)
#   bash scripts/runners/heal-external-brew-mount.sh --report   detect only (read-only)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/external-brew-mount.sh
. "$REPO/scripts/lib/external-brew-mount.sh"

REPORT=0
for a in "$@"; do
    case "$a" in
        --report|-n) REPORT=1 ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "heal-external-brew-mount: unknown arg '$a'" >&2; exit 64 ;;
    esac
done

if ! ebm_supported; then
    [[ "$REPORT" == 1 ]] && echo "external-brew mount: not macOS — n/a"
    exit 0
fi

if ! ebm_detect; then
    echo "external-brew mount: OK (no collision)"
    exit 0
fi

if [[ "$REPORT" == 1 ]]; then
    ebm_report_line
    exit 1   # read-only: a collision is a non-zero finding
fi

ebm_heal
