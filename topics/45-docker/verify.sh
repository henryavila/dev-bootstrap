#!/usr/bin/env bash
set -euo pipefail
# Only check the CLI — daemon may legitimately be stopped (Colima on Mac,
# `service docker stop` on WSL). `docker info` would false-alarm there.
if command -v docker >/dev/null 2>&1; then
    echo "  ✓ docker ($(docker --version))"
    if command -v docker-compose >/dev/null 2>&1; then
        echo "  ✓ docker-compose ($(docker-compose --version 2>&1 | head -1))"
    elif docker compose version >/dev/null 2>&1; then
        echo "  ✓ docker compose plugin ($(docker compose version 2>&1 | head -1))"
    else
        echo "  ✗ docker compose MISSING"
        exit 1
    fi
else
    echo "  ✗ docker MISSING"
    exit 1
fi
