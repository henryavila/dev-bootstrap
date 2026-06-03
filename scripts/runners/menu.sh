#!/usr/bin/env bash
# scripts/runners/menu.sh — run the Node.js interactive menu.
#
# Usage:
#   bash menu.sh [--apply]
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
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        *) log_error "unknown arg: $1"; exit 64 ;;
    esac
done

if ! command -v node >/dev/null 2>&1; then
    log_error "Node.js is required for the interactive menu."
    log_error "Install it first: brew install node (macOS) or apt install nodejs (Linux)"
    exit 1
fi

MENU_DIR="$ROOT/scripts/menu"
if [[ ! -d "$MENU_DIR/node_modules" ]]; then
    info "Installing menu dependencies..."
    # --install-links: pack the file: blink-tui dep as a real copy (dist only, no
    # bundled React) so React dedupes to one instance (else: invalid-hook crash).
    (cd "$MENU_DIR" && npm install --omit=dev --install-links --no-audit --no-fund --silent)
fi

node "$MENU_DIR/index.js" "$@"
menu_exit=$?

if (( menu_exit != 0 )); then
    exit $menu_exit
fi

if (( APPLY == 0 )); then
    exit 0
fi

SELECTIONS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/mesh/selections.list"
if [[ ! -f "$SELECTIONS_FILE" ]]; then
    log_error "No selections file found after menu run."
    exit 1
fi

info "Applying selections..."

# Manifest v2: the engine consumes the whole selections.list (topic/bundle
# entries), computes the requires_bundles closure + topological order, and
# applies them. No per-topic --manifest loop.
bash "$ROOT/scripts/lib/install-engine.sh" \
    --selections "$SELECTIONS_FILE" \
    --platform "$PLATFORM"

info "All selections applied."
