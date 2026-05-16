#!/usr/bin/env bash
# Verifies each driver source-cleanly and exports expected functions.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
DRIVERS_DIR="$WS/scripts/lib/installers"

passed=0; failed=0
for driver in "$DRIVERS_DIR"/*.sh; do
    name=$(basename "$driver" .sh)
    prefix="${name//-/_}"
    # Source in a subshell, check that ${prefix}_check and ${prefix}_install exist.
    ok=$(bash -c ". '$driver' 2>/dev/null; declare -f ${prefix}_check >/dev/null && declare -f ${prefix}_install >/dev/null && echo yes || echo no")
    if [[ "$ok" == "yes" ]]; then passed=$((passed+1)); echo "  ✓ $name exports check + install"
    else failed=$((failed+1)); echo "  ✗ $name missing check or install" >&2; fi
done

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
