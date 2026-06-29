#!/usr/bin/env bash
# L21 — no `<fatal-producer> | grep -q` / `| head` in driver + runner scripts.
#
# The install engine AND the auto-update runner run under `set -o pipefail`.
# When an early-exit consumer (`grep -q`, `grep -m`, `head`) closes the pipe on
# its first match, a producer that is still writing hits EPIPE and exits
# non-zero — a Rust binary (fnm, cargo, rustup) IGNORES SIGPIPE and PANICS
# (exit 101); a C/interpreter tool (launchctl, php) dies on SIGPIPE (141) or
# errors (255); and the bash `echo` BUILTIN reports "write error: Broken pipe"
# and returns non-zero. pipefail then adopts that non-zero rc EVEN THOUGH the
# consumer matched → an intermittent (or, for large inputs, deterministic)
# FALSE "not found"/"no sudo needed" in a check()/verify()/needs_sudo. These
# are the node-fnm rc=1 flake and the auto-update.sh:588 needs_sudo=false flake
# (F-D, root of "mesh update quase sempre falha") — see
# feedback_engine_pipefail_grep_q_broken_pipe.
#
# The safe form is capture-then-test (no pipe):
#     out="$(some_tool ... 2>/dev/null)"; [[ "$out" =~ pattern ]]
#     grep -q pattern <<<"$out"        # here-string = single command, no producer
#
# This lint is a CURATED DENYLIST rather than "any `| grep -q`":
#  - fatal binary producers: fnm|launchctl|cargo|rustup|php[0-9.]*
#  - `echo "$<var>"`: a builtin producer whose output is UNBOUNDED (a literal
#    echo '...' / "no $" is bounded → safe, NOT matched). Added for F-D.
# Single-line producers (dpkg-query, psql -tAc, pg_isready), file-arg greps,
# `printf` (its callers feed bounded input today; add it if one flakes), and
# awk-drained pipes are all safe, and flagging them would be noise. Add a
# producer here when a new one is piped to an early-exit consumer.
# Pipes with an intervening stage (e.g. `brew services list | awk … | grep -qx`)
# are NOT matched: the [^|]* below stops at the first pipe, so only a producer
# feeding the consumer DIRECTLY is flagged.
# Spec: §C21.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

# Producer tokens:
#   fatal   — bare fatal binaries or versioned php (php[0-9.]* also covers the
#             `$php_bin`/`"$php_bin"` var form, since the boundary admits `$`/`"`).
#   echo_var — `echo "<...$var...>"`, the unbounded builtin producer (F-D).
# Consumer: grep with a q/m flag (any cluster) or head. `^[^#]*` keeps the match
# out of comments; `[^|]*` stops at the FIRST pipe so only a producer feeding
# the consumer DIRECTLY is flagged (an intervening `| awk … |` drains the
# producer → not matched). To extend: add the new producer to the relevant token.
fatal='(fnm|launchctl|cargo|rustup|php[0-9.]*)'
echo_var='echo[[:space:]]+"[^"]*\$[^"]*"'
consumer='[[:space:]]*(grep[[:space:]]+-[[:alpha:]]*[qm]|head([[:space:]]|\||$))'
pattern_fatal="^[^#]*(^|[^[:alnum:]_])${fatal}[^|]*\\|${consumer}"
pattern_echo="^[^#]*${echo_var}[^|]*\\|${consumer}"

# Scan topics + the whole scripts/ tree (runners run under pipefail too —
# auto-update.sh:32; that's where F-D lived). Exclude the lint files themselves
# (their pattern strings legitimately reference these constructs) + tests/archive.
hits=""
for pat in "$pattern_fatal" "$pattern_echo"; do
    h=$(grep -rnE "$pat" \
        --include='*.sh' \
        --exclude-dir=.git --exclude-dir=tests --exclude-dir=archive --exclude-dir=lints \
        "$ROOT/topics" "$ROOT/scripts" 2>/dev/null || true)
    [[ -n "$h" ]] && hits+="$h"$'\n'
done

if [[ -n "${hits//[[:space:]]/}" ]]; then
    printf '%s' "$hits" \
        | sed "s|^$ROOT/|L21: |; s|\$| (broken-pipe race under pipefail — capture then test or use a here-string, do not pipe a fatal/echo-of-variable producer to grep -q/head; see feedback_engine_pipefail_grep_q_broken_pipe)|"
    exit 1
fi
exit 0
