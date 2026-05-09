#!/usr/bin/env bash
# tests/integration/bootstrap-topic-selection.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

TESTROOT="$(mktemp -d /tmp/dev-bootstrap-topic-selection.XXXXXX)"
trap 'rm -rf "$TESTROOT"' EXIT INT TERM

echo
echo "═══ bootstrap topic selection ═══"

list_out="$(HOME="$TESTROOT/home-list" bash "$REPO_ROOT/bootstrap.sh" --list-topics 2>&1)"
assert_contains "$list_out" "20  20-terminal-ux" \
    "bootstrap --list-topics lists topic numbers from topics/"
assert_contains "$list_out" "60  60-web-stack" \
    "bootstrap --list-topics includes opt-in topics"

dry_out="$(
    HOME="$TESTROOT/home-dry" \
    ONLY_TOPICS="20 30" \
    DRY_RUN=1 \
    NON_INTERACTIVE=1 \
        bash "$REPO_ROOT/bootstrap.sh" --non-interactive 2>&1
)"
assert_contains "$dry_out" "topic :: 20-terminal-ux" \
    "ONLY_TOPICS accepts short numeric selector 20"
assert_contains "$dry_out" "topic :: 30-shell" \
    "ONLY_TOPICS accepts short numeric selector 30"
assert_not_contains "$dry_out" "topic :: 40-tmux" \
    "ONLY_TOPICS numeric selectors do not run unrelated topics"

single_digit_out="$(
    HOME="$TESTROOT/home-single" \
    ONLY_TOPICS="5" \
    DRY_RUN=1 \
    NON_INTERACTIVE=1 \
        bash "$REPO_ROOT/bootstrap.sh" --non-interactive 2>&1
)"
assert_contains "$single_digit_out" "topic :: 05-identity" \
    "ONLY_TOPICS accepts single-digit selector 5 for 05-identity"

bad_out="$(
    HOME="$TESTROOT/home-bad" \
    ONLY_TOPICS="25" \
    DRY_RUN=1 \
    NON_INTERACTIVE=1 \
        bash "$REPO_ROOT/bootstrap.sh" --non-interactive 2>&1
)"
bad_rc=$?
if (( bad_rc != 0 )) && [[ "$bad_out" == *"unknown topic selector '25'"* ]]; then
    pass "unknown numeric topic selector fails before running topics"
else
    fail "unknown numeric topic selector should fail loudly (rc=$bad_rc)"
    printf '%s\n' "$bad_out" | sed 's/^/        /' >&2
fi

strict_out="$(
    HOME="$TESTROOT/home-strict" \
    INCLUDE_WEBSTACK=0 \
    ONLY_TOPICS="60" \
    DEV_BOOTSTRAP_REQUIRE_ONLY_TOPICS=1 \
    DRY_RUN=1 \
    NON_INTERACTIVE=1 \
        bash "$REPO_ROOT/bootstrap.sh" --non-interactive 2>&1
)"
strict_rc=$?
if (( strict_rc != 0 )) && [[ "$strict_out" == *"60-web-stack is opt-in; set INCLUDE_WEBSTACK=1"* ]]; then
    pass "strict topic mode fails when an explicitly requested opt-in topic is disabled"
else
    fail "strict topic mode should fail for disabled opt-in topic (rc=$strict_rc)"
    printf '%s\n' "$strict_out" | sed 's/^/        /' >&2
fi

summary
