#!/usr/bin/env bash
# tests/run-all.sh — discovers and runs every *.test.sh + deploy-smoke.sh
# under tests/. Each test file is self-contained; this orchestrator only
# aggregates exit codes.
#
# Run:
#   bash tests/run-all.sh                 # run everything
#   bash tests/run-all.sh unit            # only tests under tests/unit/
#   bash tests/run-all.sh cli/php-use     # single test (file extension optional)
#   VERBOSE=1 bash tests/run-all.sh       # don't suppress test stdout
#
# Exit 0 if every test file exits 0. Exit 1 if any fails — the summary
# lists which files failed so CI logs point at the right place.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
filter="${1:-}"
VERBOSE="${VERBOSE:-0}"

# Colors
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    c_ok=$'\033[32m'; c_err=$'\033[31m'; c_bold=$'\033[1m'
    c_dim=$'\033[2m'; c_reset=$'\033[0m'
else
    c_ok=""; c_err=""; c_bold=""; c_dim=""; c_reset=""
fi

# Discover tests
mapfile -t all_tests < <(
    find "$HERE" -type f \( -name '*.test.sh' -o -name 'deploy-smoke.sh' \) \
        | sort
)

# Filter (if arg given, keep paths containing that substring — case-insensitive)
tests=()
for t in "${all_tests[@]}"; do
    rel="${t#"$HERE"/}"
    if [[ -n "$filter" ]]; then
        if [[ "${rel,,}" == *"${filter,,}"* ]]; then
            tests+=("$t")
        fi
    else
        tests+=("$t")
    fi
done

if [[ "${#tests[@]}" -eq 0 ]]; then
    echo "no tests matched filter: ${filter:-<none>}" >&2
    exit 1
fi

# Run
pass_files=()
fail_files=()
total=${#tests[@]}

echo "${c_bold}Running ${total} test file(s)${c_reset}"
echo

for test_file in "${tests[@]}"; do
    rel="${test_file#"$HERE"/}"
    printf "${c_dim}── %s${c_reset}\n" "$rel"

    if [[ "$VERBOSE" == "1" ]]; then
        if bash "$test_file"; then
            pass_files+=("$rel")
            printf "${c_ok}▶ PASS${c_reset} %s\n\n" "$rel"
        else
            fail_files+=("$rel")
            printf "${c_err}▶ FAIL${c_reset} %s\n\n" "$rel"
        fi
    else
        # Capture output; show on failure only
        out_file="$(mktemp)"
        if bash "$test_file" > "$out_file" 2>&1; then
            pass_files+=("$rel")
            # Show the ✓ lines (from assert.sh) for signal without the full log
            grep -E '^\s*(✓|✗)' "$out_file" | sed 's/^/  /' || true
            printf "${c_ok}▶ PASS${c_reset} %s\n\n" "$rel"
        else
            fail_files+=("$rel")
            cat "$out_file"
            printf "${c_err}▶ FAIL${c_reset} %s\n\n" "$rel"
        fi
        rm -f "$out_file"
    fi
done

# Summary
echo "${c_bold}── summary${c_reset}"
printf "  ${c_ok}%d passed${c_reset}: %s\n" \
    "${#pass_files[@]}" "${pass_files[*]:-(none)}"
if [[ "${#fail_files[@]}" -gt 0 ]]; then
    printf "  ${c_err}%d failed${c_reset}: %s\n" \
        "${#fail_files[@]}" "${fail_files[*]}"
    exit 1
fi

echo
echo "${c_ok}all test files passed${c_reset}"
