#!/usr/bin/env bash
# Topic 90-editor — thin engine dispatcher.
# The typora wrappers under templates/bin/ are deployed by setup.sh's
# templates/ pass; this script wires the engine to link the nvim default
# config (the only item that needs scripted logic).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_DIR="${MESH_WORKSTATION_DIR:-$(cd "$HERE/../.." && pwd)}"
WS_LIB="$(cd "$HERE/../../scripts/lib" 2>/dev/null && pwd)" || WS_LIB="$WS_DIR/scripts/lib"

( cd "$HERE" && bash "$WS_LIB/install-engine.sh" \
    --manifest "$HERE/items.yaml" \
    --installers-dir "$WS_LIB/installers" )
