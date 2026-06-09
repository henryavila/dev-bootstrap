#!/usr/bin/env bash
# L21 — no `<fatal-producer> | grep -q` / `| head` in driver scripts.
#
# The install engine runs drivers under `set -o pipefail`. When an early-exit
# consumer (`grep -q`, `grep -m`, `head`) closes the pipe on its first match, a
# producer that is still writing hits EPIPE and exits non-zero — a Rust binary
# (fnm, cargo, rustup) IGNORES SIGPIPE and PANICS (exit 101); a C/interpreter
# tool (launchctl, php) dies on SIGPIPE (141) or errors (255). pipefail then
# adopts that non-zero rc EVEN THOUGH the consumer matched → an intermittent
# (~50%) FALSE "not found" in a check()/verify(). This is the node-fnm rc=1
# flake (see feedback_engine_pipefail_grep_q_broken_pipe).
#
# The safe form is capture-then-test (no pipe):
#     out="$(some_tool ... 2>/dev/null)"; [[ "$out" =~ pattern ]]
#     grep -q pattern <<<"$out"        # here-string = temp file, no producer
#
# This lint is a CURATED DENYLIST of the known SIGPIPE/EPIPE-fatal producers
# rather than "any `| grep -q`": single-line producers (dpkg-query, psql -tAc,
# pg_isready), file-arg greps, builtin producers (printf/echo) and awk-drained
# pipes are all safe, and flagging them would be noise. Add a producer here when
# a new Rust/Go/interpreter tool is piped to an early-exit consumer in a driver.
# Pipes with an intervening stage (e.g. `brew services list | awk … | grep -qx`)
# are NOT matched: the [^|]* below stops at the first pipe, so only a producer
# feeding the consumer DIRECTLY is flagged.
# Spec: §C21.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

# Producer token: bare fatal commands or versioned php (php[0-9.]* also covers the
# `$php_bin`/`"$php_bin"` var form, since the boundary admits `$`/`"`). Consumer:
# grep with a q/m flag (any cluster) or head. `^[^#]*` keeps the match out of
# comments; `[^|]*` stops at the FIRST pipe so only a producer feeding the consumer
# DIRECTLY is flagged (an intervening `| awk … |` drains the producer → not matched).
# To extend: add the new fatal producer to the alternation below.
pattern='^[^#]*(^|[^[:alnum:]_])(fnm|launchctl|cargo|rustup|php[0-9.]*)[^|]*\|[[:space:]]*(grep[[:space:]]+-[[:alpha:]]*[qm]|head([[:space:]]|\||$))'

hits=$(grep -rnE "$pattern" \
    --include='*.sh' \
    --exclude-dir=.git --exclude-dir=tests --exclude-dir=archive \
    "$ROOT/topics" "$ROOT/scripts/lib/installers" 2>/dev/null || true)

if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" \
        | sed "s|^$ROOT/|L21: |; s|\$| (broken-pipe race under engine pipefail — capture then test, do not pipe a fatal producer to grep -q/head; see feedback_engine_pipefail_grep_q_broken_pipe)|"
    exit 1
fi
exit 0
