#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
. "$WS/scripts/lib/perms.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
touch "$TMP/f"
apply_perms "$TMP/f" 0600
actual=$(stat -f %p "$TMP/f" 2>/dev/null || stat -c '%a' "$TMP/f")
case "$actual" in
    *600) echo "  ✓ apply_perms 0600"; exit 0 ;;
    *)    echo "  ✗ apply_perms 0600 — got $actual" >&2; exit 1 ;;
esac
