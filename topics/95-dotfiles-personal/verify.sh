#!/usr/bin/env bash
set -euo pipefail
: "${MESH_IDENTITY_DIR:=$HOME/mesh-identity}"
if [[ -d "$MESH_IDENTITY_DIR/.git" ]]; then
    echo "  ✓ $MESH_IDENTITY_DIR (git repo)"
else
    echo "  ✗ $MESH_IDENTITY_DIR MISSING"
    exit 1
fi
