#!/usr/bin/env bash
# Topic 45-docker — thin dispatcher.
# Resolves engine paths and invokes install-engine.sh with this topic's
# items.yaml. The engine's platforms: filter picks the correct subset
# (3 brew-formula items on mac, 3 apt items + 1 custom on wsl).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_DIR="${MESH_WORKSTATION_DIR:-$(cd "$HERE/../.." && pwd)}"
WS_LIB="$(cd "$HERE/../../scripts/lib" 2>/dev/null && pwd)" || WS_LIB="$WS_DIR/scripts/lib"

# Resolve relative script paths in items.yaml against this topic dir so
# `script: "./post-setup-wsl.sh"` finds topics/45-docker/post-setup-wsl.sh.
( cd "$HERE" && bash "$WS_LIB/install-engine.sh" \
    --manifest "$HERE/items.yaml" \
    --installers-dir "$WS_LIB/installers" )
