#!/usr/bin/env bash
# Wrapper: plan F1 verifier path tests/unit/no-mesh-menu → vitest in scripts/menu.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
cd "$WS/scripts/menu"
npx vitest run tests/no-mesh-menu.test.ts
exit $?
