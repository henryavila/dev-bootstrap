#!/usr/bin/env bash
# scripts/lib/lint.sh — orchestrates all lints in scripts/lib/lints/L*.sh.
#
# Contract for each lint script (Phase 5 / C21):
#   - Lives at scripts/lib/lints/L<NN>-<slug>.sh and is executable.
#   - Receives no arguments and reads no stdin; scans repo root via its own grep/find.
#   - Resolves $ROOT relative to $BASH_SOURCE so it works from any cwd.
#   - rc=0 when clean; rc!=0 when violations found.
#   - Prints violations to stdout in the format "L<NN>: <file>:<line>: <message>".
#
# Orchestrator behavior:
#   - Runs every lints/L*.sh discovered (sorted lexicographically).
#   - Tallies failures; exit code = number of failing lints (capped at 125 for shell).
#   - On clean tree: rc=0, no output.
#   - On failures: each failing lint's stdout is forwarded as-is; trailer summary
#     "lint: N lint(s) failed" goes to stderr.
#
# Bash 3.2 compatible (macOS default).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINTS_DIR="$HERE/lints"

if [[ ! -d "$LINTS_DIR" ]]; then
    printf 'lint: missing lints dir at %s\n' "$LINTS_DIR" >&2
    exit 2
fi

shopt -s nullglob
lints=("$LINTS_DIR"/L*.sh)
shopt -u nullglob

if (( ${#lints[@]} == 0 )); then
    printf 'lint: no lint scripts found in %s\n' "$LINTS_DIR" >&2
    exit 0
fi

failed=0
for lint in "${lints[@]}"; do
    if ! bash "$lint"; then
        failed=$((failed + 1))
    fi
done

if (( failed > 0 )); then
    printf 'lint: %d lint(s) failed\n' "$failed" >&2
    if (( failed > 125 )); then
        exit 125
    fi
    exit "$failed"
fi

exit 0
