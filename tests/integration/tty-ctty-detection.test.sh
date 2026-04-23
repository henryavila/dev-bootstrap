#!/usr/bin/env bash
# tests/integration/tty-ctty-detection.test.sh
#
# Behavioral regression for the TTY-detection bug that silenced every
# interactive fallback shipped on 2026-04-23 (chsh `sudo` prompt, atuin
# inline login). Root cause: bootstrap.sh:371 wraps each installer as
#
#     bash "$installer" 2>&1 | tee -a "$LOG"
#
# The pipe makes stdout a pipe (not a TTY) from the installer's view,
# so `[ -t 1 ]` evaluates false on every real run. Any interactive
# fallback gated on it is silently dead. Static grep tests passed
# (the pattern was in the code) but the branch never executed.
#
# This test ACTUALLY RUNS the gate under the same `| tee` wrapping,
# asserting what every gate relies on: `_has_ctty` stays true while
# `[ -t 1 ]` flips false. A contributor who reintroduces `-t 1` as the
# gate (or loses `/dev/tty` somewhere) fails this test immediately.
#
# Skip policy:
#   - No controlling TTY available (CI, detached shell, container):
#     skip gracefully. The whole class of bugs is TTY-specific by
#     definition, so running this without a TTY is a category error.
#   - The run-all orchestrator captures test stdout via `$(...)` in
#     non-VERBOSE mode, which makes this file's stdout a pipe — that
#     does NOT disqualify the test. What matters is whether the
#     process has a controlling terminal (ctty), inherited via the
#     process group from the user's interactive shell. `/dev/tty`
#     is the only canonical indicator of that.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

# Probe: does this process have a controlling terminal?
# If not (CI runner, container, cron), this whole test file is moot —
# every assertion below is about pty-dependent behavior. Exit cleanly
# so run-all.sh doesn't flag it as a failure.
if ! : </dev/tty >/dev/null 2>&1; then
    echo "  ⏭  skipped — no controlling TTY (CI / detached shell / container)"
    echo "0/0 passed"
    exit 0
fi

# Reusable predicate exactly matching the copy in install.{wsl,mac}.sh.
# Kept inline rather than sourced from the install scripts — those files
# exec apt/brew on source, too invasive for a test. Static regression
# tests in regression-recent-fixes.test.sh cover "install scripts define
# this function" + "install scripts use this function"; this test covers
# "the function actually does the right thing under the real pipeline".
_has_ctty_def='_has_ctty() { : </dev/tty >/dev/null 2>&1; }'

echo
echo "═══ [ -t 1 ] is false under bootstrap's 'tee' pipe (document the bug) ═══"

# Mimic bootstrap.sh:371 — child's stdout is piped to tee, which then
# writes to /dev/null AND its own stdout (captured here by `$(...)`).
# `2>&1 | tee ...` is the exact incantation bootstrap.sh uses.
wrap_out="$(
    bash -c '
        if [ -t 1 ]; then echo STDOUT_IS_TTY; else echo STDOUT_NOT_TTY; fi
    ' 2>&1 | tee /dev/null
)"

assert_contains "$wrap_out" "STDOUT_NOT_TTY" \
    "bash child under '| tee' sees stdout as NOT a tty — this is the trap"

assert_not_contains "$wrap_out" "STDOUT_IS_TTY" \
    "no false-positive 'stdout is tty' under pipe wrap"

echo
echo "═══ _has_ctty stays true under the same tee pipe (the fix) ═══"

# Same wrap, checking _has_ctty. Must be true — that's the whole point
# of switching from fd-tests to `/dev/tty` open-test.
ctty_out="$(
    bash -c "
        $_has_ctty_def
        if _has_ctty; then echo HAS_CTTY; else echo NO_CTTY; fi
    " 2>&1 | tee /dev/null
)"

assert_contains "$ctty_out" "HAS_CTTY" \
    "_has_ctty detects controlling terminal under bootstrap's tee pipe"

assert_not_contains "$ctty_out" "NO_CTTY" \
    "_has_ctty does not falsely report missing ctty under tee pipe"

echo
echo "═══ The interactive-fallback branch is actually reachable ═══"

# Replicate the gate the installers use verbatim:
#     elif _has_ctty && [ "${NON_INTERACTIVE:-0}" != "1" ]; then ...
# If this test fails, the chsh prompt and atuin inline login are dead
# code in production — exactly the regression we are preventing.
branch_out="$(
    bash -c "
        $_has_ctty_def
        if _has_ctty && [ \"\${NON_INTERACTIVE:-0}\" != \"1\" ]; then
            echo BRANCH_INTERACTIVE_FALLBACK
        else
            echo BRANCH_ADVISORY_ONLY
        fi
    " 2>&1 | tee /dev/null
)"

assert_contains "$branch_out" "BRANCH_INTERACTIVE_FALLBACK" \
    "interactive fallback branch executes under bootstrap's tee pipe"

assert_not_contains "$branch_out" "BRANCH_ADVISORY_ONLY" \
    "does not fall through to advisory-only path when ctty is present"

echo
echo "═══ NON_INTERACTIVE=1 forces advisory path even with ctty ═══"

# The automation opt-out must win. CI runs that happen to have a ctty
# should still skip the interactive fallback if asked to.
ni_out="$(
    NON_INTERACTIVE=1 bash -c "
        $_has_ctty_def
        if _has_ctty && [ \"\${NON_INTERACTIVE:-0}\" != \"1\" ]; then
            echo BRANCH_INTERACTIVE_FALLBACK
        else
            echo BRANCH_ADVISORY_ONLY
        fi
    " 2>&1 | tee /dev/null
)"

assert_contains "$ni_out" "BRANCH_ADVISORY_ONLY" \
    "NON_INTERACTIVE=1 forces advisory path even when ctty is available"

assert_not_contains "$ni_out" "BRANCH_INTERACTIVE_FALLBACK" \
    "NON_INTERACTIVE=1 does not let the interactive fallback fire"

echo
echo "═══ No-ctty context (setsid) falls through to advisory ═══"

# Optional half — only Linux ships setsid by default. macOS doesn't have
# it in /usr/bin, and we don't want to require `brew install util-linux`
# to run this test. When setsid is present, verify the advisory path
# is the one that fires.
if command -v setsid >/dev/null 2>&1; then
    # `|| true` because setsid of a failing child propagates non-zero
    # exit; we care about the output text, not the exit code.
    noctty_out="$(
        setsid bash -c "
            $_has_ctty_def
            if _has_ctty && [ \"\${NON_INTERACTIVE:-0}\" != \"1\" ]; then
                echo BRANCH_INTERACTIVE_FALLBACK
            else
                echo BRANCH_ADVISORY_ONLY
            fi
        " 2>&1 | tee /dev/null || true
    )"

    assert_contains "$noctty_out" "BRANCH_ADVISORY_ONLY" \
        "setsid (no ctty) correctly routes to advisory-only path"

    assert_not_contains "$noctty_out" "BRANCH_INTERACTIVE_FALLBACK" \
        "setsid (no ctty) does not attempt interactive fallback"
else
    echo "  ⏭  setsid not present — skipping no-ctty half (macOS default)"
fi

summary
