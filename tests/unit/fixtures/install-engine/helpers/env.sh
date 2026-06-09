#!/usr/bin/env bash
# Minimal env.sh helpers (subset of C19 spec).
case "$(uname -s)" in
    Darwin) MESH_OS=mac ;;
    Linux)  MESH_OS=linux ;;
    *)      MESH_OS=unknown ;;
esac
export MESH_OS

is_mac()   { [ "$MESH_OS" = "mac" ]; }
is_linux() { [ "$MESH_OS" = "linux" ]; }
