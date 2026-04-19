#!/usr/bin/env bash
# lib/detect-os.sh — prints one of: wsl | mac | linux | unknown
set -euo pipefail

case "$(uname -s)" in
    Darwin)
        echo "mac"
        ;;
    Linux)
        if grep -qi microsoft /proc/version 2>/dev/null; then
            echo "wsl"
        else
            echo "linux"
        fi
        ;;
    *)
        echo "unknown"
        ;;
esac
