#!/usr/bin/env bash
# Topic 82-ai-tools — thin dispatcher.
# Resolves engine paths and invokes install-engine.sh with this topic's items.yaml.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_DIR="${MESH_WORKSTATION_DIR:-/Volumes/External/code/dev-bootstrap}"
# Locate engine relative to this file's git toplevel (more reliable than env in tests):
WS_LIB="$(cd "$HERE/../../scripts/lib" 2>/dev/null && pwd)" || WS_LIB="$WS_DIR/scripts/lib"

# Resolve relative script paths in items.yaml against this topic dir so
# `script: "./install-rtk.sh"` finds topics/82-ai-tools/install-rtk.sh.
( cd "$HERE" && bash "$WS_LIB/install-engine.sh" \
    --manifest "$HERE/items.yaml" \
    --installers-dir "$WS_LIB/installers" )
