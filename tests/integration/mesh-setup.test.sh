#!/usr/bin/env bash
# Integration test for `mesh setup` (bin/mesh) — the convenience wrapper that
# (by default) runs `mesh update` then execs setup.sh, so the user can bootstrap
# from any directory without `cd`-ing into the checkout or typing `bash setup.sh`.
#
# Exercises ONLY the --no-update path (read-only `setup.sh --list-bundles`) so
# the test never pulls or installs. The default path's update step is just a
# child `mesh update`, covered by the auto-update suite.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
MESH="$REPO_ROOT/bin/mesh"
# shellcheck source=../lib/assert.sh
source "$SELF_DIR/../lib/assert.sh"

# ── -h is intercepted by sub_setup: prints usage, runs no update, no setup.sh ──
help_out="$(bash "$MESH" setup -h 2>&1)"; help_rc=$?
assert_eq "$help_rc" "0" "setup -h exits 0"
assert_contains "$help_out" "mesh setup [--no-update]" "setup -h shows usage"
assert_contains "$help_out" "mesh update" "setup -h documents the update-first default"
assert_not_contains "$help_out" "mesh setup: running" "setup -h does NOT run setup.sh"

# ── --no-update runs setup.sh directly, from an UNRELATED cwd, read-only ──
# Proves: runs from anywhere (cd /tmp), resolves the workstation setup.sh,
# consumes --no-update (else setup.sh would reject the unknown flag), and passes
# the remaining args through (--list-bundles reaches setup.sh and lists).
run_out="$(cd /tmp && bash "$MESH" setup --no-update --list-bundles 2>&1)"; run_rc=$?
assert_eq "$run_rc" "0" "setup --no-update --list-bundles exits 0 from /tmp"
assert_contains "$run_out" "mesh setup: running" "announces it execs setup.sh"
assert_contains "$run_out" "$REPO_ROOT/setup.sh" "resolves the workstation setup.sh regardless of cwd"
assert_contains "$run_out" "default on" "passed --list-bundles through to setup.sh (bundles listed)"

# ── an unreadable HERE/../setup.sh would be caught — sanity: the file exists ──
assert_file_exists "$REPO_ROOT/setup.sh" "setup.sh present at the resolved path"

summary
