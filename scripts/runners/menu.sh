#!/usr/bin/env bash
# scripts/runners/menu.sh — run the Node.js interactive menu.
#
# Usage:
#   bash menu.sh [--apply]
#   bash menu.sh help
#
# Without --apply: runs the selector, writes selections.list + params.env.
# With --apply: runs the selector, then executes the install/uninstall delta
# via install-engine.sh and uninstall-engine.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# shellcheck disable=SC1091
. "$ROOT/scripts/lib/log.sh"
# detect-os.sh PRINTS the platform (mac|wsl|linux|unknown) to stdout — it does
# NOT set an $OS variable. Run it and capture stdout, exactly as the engines do
# (install-engine.sh / uninstall-engine.sh). Sourcing it and reading $OS tripped
# `set -u` ("OS: unbound variable") and crashed `mesh menu` before launch.
PLATFORM="$(bash "$ROOT/scripts/lib/detect-os.sh" 2>/dev/null || echo unknown)"

APPLY=0
MODE="wizard"
while [[ $# -gt 0 ]]; do
    case "$1" in
        help) MODE="help"; shift ;;
        --apply) APPLY=1; shift ;;
        *) log_error "unknown arg: $1"; exit 64 ;;
    esac
done

if [[ "$MODE" == "help" && "$APPLY" -eq 1 ]]; then
    log_error "help cannot be combined with --apply"
    exit 64
fi

if ! command -v node >/dev/null 2>&1; then
    log_error "Node.js is required for the interactive menu."
    log_error "Install it first: brew install node (macOS) or apt install nodejs (Linux)"
    exit 1
fi

MENU_DIR="$ROOT/scripts/menu"
# Dependency provisioning lives in the launcher (scripts/menu/index.js): it is
# the single entry every path runs, so it `npm ci`s against the committed
# lockfile on a missing OR drifted node_modules — no guard duplicated here. If
# it cannot provision (offline), index.js exits non-zero, propagated below.
if [[ "$MODE" == "help" ]]; then
    node "$MENU_DIR/index.js" help
else
    node "$MENU_DIR/index.js" "$@"
fi
menu_exit=$?

if (( menu_exit != 0 )); then
    exit $menu_exit
fi

if (( APPLY == 0 )); then
    exit 0
fi

SELECTIONS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/mesh/selections.list"
REMOVALS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/mesh/removals.list"
if [[ ! -f "$SELECTIONS_FILE" ]]; then
    log_error "No selections file found after menu run."
    exit 1
fi

info "Applying selections..."

# The TUI writes bundles deselected since the previous apply to removals.list.
# Run uninstall before install so a re-selected dependency can be installed
# cleanly by the install pass below. uninstall-engine itself expands bundles to
# their listed items and keeps markers honest when custom uninstall() is absent.
if [[ -s "$REMOVALS_FILE" ]] && grep -qvE '^[[:space:]]*(#|$)' "$REMOVALS_FILE"; then
    info "Applying removals..."
    uninstall_rc=0
    bash "$ROOT/scripts/lib/uninstall-engine.sh" \
        --selections "$REMOVALS_FILE" \
        --platform "$PLATFORM" || uninstall_rc=$?
    if [[ "$uninstall_rc" -ne 0 ]]; then
        log_warn "uninstall pass exited rc=$uninstall_rc — continuing to install"
    else
        rm -f "$REMOVALS_FILE"
    fi
fi

# Manifest v2: the engine consumes the whole selections.list (topic/bundle
# entries), computes the requires_bundles closure + topological order, and
# applies them. No per-topic --manifest loop.
bash "$ROOT/scripts/lib/install-engine.sh" \
    --selections "$SELECTIONS_FILE" \
    --platform "$PLATFORM"

info "All selections applied."
