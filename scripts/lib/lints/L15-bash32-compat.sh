#!/usr/bin/env bash
# L15 — bash 3.2 compat. macOS default bash is 3.2 (frozen for GPL-3 reasons).
# Any script that runs on Mac must avoid bash-4+ builtins.
#
# Ported from legacy tests/integration/lint.test.sh (G1 hybrid migration).
# Flagged builtins: mapfile, readarray, declare -A.
# Strategy: scan Mac-reachable scripts, ignore comment-only lines, use word
# boundaries to avoid false positives like `_mapfile_helper`. Strip trailing
# inline comments before re-checking. scripts/lib/lints/ excluded because
# lints by necessity reference the patterns they detect.
#
# Spec: §C21. Phase 5 Task 5.2.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

bash4_patterns=(mapfile readarray)
# declare -A handled separately because of the space.

mac_reachable=(
    "$ROOT/topics"/*/install.mac.sh
    "$ROOT/topics"/*/install.sh
    "$ROOT/topics"/*/scripts/*.sh
    "$ROOT/scripts/lib"/*.sh
    "$ROOT/scripts/lib/installers"/*.sh
    "$ROOT/scripts/runners"/*.sh
    "$ROOT/scripts/internal"/*
    "$ROOT/bin/mesh"
    "$ROOT/setup.sh"
)

_check_pattern() {
    local script="$1" rx="$2" label="$3"
    local linenum content stripped found=0
    while IFS=: read -r linenum content; do
        [[ -z "$linenum" ]] && continue
        # Skip lines that are entirely a comment (leading whitespace + #).
        [[ "$content" =~ ^[[:space:]]*# ]] && continue
        # Strip trailing inline comment (best-effort; ignores # inside quotes).
        stripped="${content%%#*}"
        if [[ "$stripped" =~ $rx ]]; then
            printf 'L15: %s:%s: no bash 4+ %s in Mac-reachable scripts\n' \
                "${script#"$ROOT"/}" "$linenum" "$label"
            found=1
        fi
    done < <(grep -nE "$rx" "$script" 2>/dev/null)
    return "$found"
}

failed=0
for script in "${mac_reachable[@]}"; do
    [[ -f "$script" ]] || continue
    # Exclude the lints dir; meta-tools necessarily reference these tokens.
    case "$script" in
        "$ROOT/scripts/lib/lints/"*) continue ;;
    esac
    for pat in "${bash4_patterns[@]}"; do
        _check_pattern "$script" "(^|[^a-zA-Z_])${pat}([^a-zA-Z_]|\$)" "$pat" || failed=1
    done
    # declare -A — two-token form.
    _check_pattern "$script" "(^|[^a-zA-Z_])declare[[:space:]]+-A([^a-zA-Z_]|\$)" "declare -A" || failed=1
done

exit "$failed"
