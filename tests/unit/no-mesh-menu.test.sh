#!/usr/bin/env bash
# Wrapper: plan F1 verifier path tests/unit/no-mesh-menu → vitest in scripts/menu.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)" || exit 1
WS="$(cd "$HERE/../.." && pwd)" || exit 1
cd "$WS/scripts/menu" || exit 1
npx vitest run tests/no-mesh-menu.test.ts
exit $?
