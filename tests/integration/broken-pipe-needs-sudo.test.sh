#!/usr/bin/env bash
# tests/integration/broken-pipe-needs-sudo.test.sh
#
# Regression for F-D (initiative autoupdate-robustness, phase P2).
# scripts/runners/auto-update.sh decided `needs_sudo` via
#   echo "$diff_content" | grep -qE "$AUTO_UPDATE_SUDO_REGEX"
# under `set -o pipefail` (auto-update.sh:32). With a diff larger than the pipe
# buffer, `grep -q` matched early and closed the pipe → the `echo` builtin hit
# EPIPE ("write error: Broken pipe") and returned non-zero → under pipefail the
# pipeline returned non-zero → needs_sudo wrongly stayed 0 → the sudo prompt
# was skipped → install scripts that needed sudo failed partway. This was
# 100% reproducible on large sudo-needing diffs (root of "mesh update quase
# sempre falha"; surfaced live on mac 2026-06-29).
#
# Fix: grep over a here-string (a single command, NOT a pipeline), so pipefail
# and EPIPE cannot apply. This test pins the behavioral fix + guards against
# reintroducing the `echo "$diff_content" | grep -q` form.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
RUNNER="$WS/scripts/runners/auto-update.sh"

passed=0; failed=0
ok()  { passed=$((passed+1)); echo "  ✓ $1"; }
bad() { failed=$((failed+1)); echo "  ✗ $1" >&2; }

# The repo's sudo regex (auto-update.sh:137). If it drifts, mirror it here.
R='\b(apt|brew|pip install|npm i |chsh|sudo)\b|curl[^|]*\|[^|]*sh'

needs() {  # needs <diff> → echoes 1 if the diff needs sudo, else 0 (the fixed form)
    local _rc=0
    grep -qE "$R" <<<"$1" || _rc=$?
    (( _rc == 0 )) && printf 1 || printf 0
}

# ── 1. large diff (~140KB) with an early sudo match → needs_sudo=1 ─────────────
# The OLD echo|grep-q form returned 0 here (EPIPE false-negative). The here-string
# form must still report sudo needed.
big=$'sudo apt upgrade something\n'$(printf 'no-match-line-%s\n' {1..9000})
[[ "$(needs "$big")" == 1 ]] \
    && ok "large diff w/ early sudo match → needs_sudo=1 (no EPIPE false-negative)" \
    || bad "large diff w/ match: needs_sudo=0 (expected 1 — here-string regressed?)"

# ── 2. large diff with NO sudo match → needs_sudo=0 ───────────────────────────
nomatch=$(printf 'plain-change-line-%s\n' {1..9000})
[[ "$(needs "$nomatch")" == 0 ]] \
    && ok "large diff w/ no sudo match → needs_sudo=0" \
    || bad "no-match large diff: needs_sudo=1 (expected 0)"

# ── 3. small diff → behavior unchanged (regression guard) ─────────────────────
[[ "$(needs $'brew install ripgrep\n')" == 1 ]] \
    && ok "small diff w/ match → needs_sudo=1 (unchanged)" \
    || bad "small diff w/ match: needs_sudo=0 (expected 1)"
[[ "$(needs $'docs: tweak readme\n')" == 0 ]] \
    && ok "small diff w/ no match → needs_sudo=0 (unchanged)" \
    || bad "small diff w/ no match: needs_sudo=1 (expected 0)"

# ── 4. STATIC anti-reintro: the runner must use the here-string form ──────────
if grep -qF 'grep -qE "$AUTO_UPDATE_SUDO_REGEX" <<<"$diff_content"' "$RUNNER"; then
    ok "static: needs_sudo uses the here-string form (grep ... <<<\"\$diff_content\")"
else
    bad "static: needs_sudo is NOT using the here-string form"
fi
# Strip full-line comments first: the fix-site comment deliberately quotes the
# old form to explain why it's avoided, so a naive grep would false-positive on it.
if grep -vE '^[[:space:]]*#' "$RUNNER" | grep -qF 'echo "$diff_content" | grep'; then
    bad "static: \`echo \"\$diff_content\" | grep\` reintroduced in CODE at the needs_sudo site (F-D regression)"
else
    ok "static: no \`echo \"\$diff_content\" | grep\` in code at the needs_sudo site"
fi

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
