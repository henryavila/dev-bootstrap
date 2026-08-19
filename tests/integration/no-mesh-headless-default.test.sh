#!/usr/bin/env bash
# F1 T-002 — headless --no-mesh default is foundation/base only; --bundle adds
# php and still excludes personal. Dry-run / list capture — no package installs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

SETUP="$WS/setup.sh"
HELPER="$WS/scripts/lib/no-mesh.sh"

assert_file_exists "$SETUP" "setup.sh exists"
assert_file_exists "$HELPER" "scripts/lib/no-mesh.sh exists"

# shellcheck source=/dev/null
. "$HELPER"

# --- helper contract ---
# shellcheck disable=SC2034 # MESH_NO_MESH is read by no_mesh_active in helpers below
MESH_NO_MESH=1
default="$(no_mesh_emit_headless_default)"
assert_eq "$default" "foundation/base" "no_mesh_emit_headless_default prints foundation/base"

bundled="$(no_mesh_emit_default_or_bundles languages/php)"
assert_contains "$bundled" "foundation/base" "explicit --bundle keeps foundation/base"
assert_contains "$bundled" "languages/php" "explicit --bundle includes languages/php"
assert_not_contains "$bundled" "personal/" "explicit --bundle does not add personal"

MESH_NO_MESH=0
if no_mesh_emit_default_or_bundles >/dev/null 2>&1; then
    fail "no_mesh_emit_default_or_bundles returns nonzero when unflagged"
else
    pass "no_mesh_emit_default_or_bundles returns nonzero when unflagged"
fi
unset MESH_NO_MESH

# --- setup.sh wiring ---
assert_file_contains "$SETUP" 'no_mesh_emit_default_or_bundles' \
    "setup.sh emit_default_selections uses no_mesh_emit_default_or_bundles"
# grep treats a pattern starting with -- as options; match the case-arm suffix.
assert_file_contains "$SETUP" 'bundle)' \
    "setup.sh parses --bundle"

# --- headless write: no selections file → only foundation/base ---
TMP="$(mktemp -d /tmp/no-mesh-headless.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

home1="$TMP/home-default"
mkdir -p "$home1"
out1=""
rc1=0
out1="$(
    HOME="$home1" \
    XDG_CONFIG_HOME="$home1/.config" \
    XDG_STATE_HOME="$home1/.local/state" \
    NON_INTERACTIVE=1 \
    bash "$SETUP" --no-mesh --non-interactive --dry-run 2>&1
)" || rc1=$?

sel1="$home1/.config/mesh/selections.list"
assert_file_exists "$sel1" "no-mesh dry-run persists selections.list under isolated HOME"
body1="$(grep -vE '^[[:space:]]*(#|$)' "$sel1" || true)"
assert_eq "$body1" "foundation/base" \
    "no-mesh headless default selections.list is only foundation/base"
assert_not_contains "$body1" "personal/" "default list excludes personal"
assert_not_contains "$body1" "identity/" "default list excludes identity"
assert_not_contains "$body1" "git/config" "default list excludes unlock git/config"
assert_not_contains "$body1" "shell-terminal/" "default list excludes unlock shell-terminal"

assert_eq "$rc1" "0" "no-mesh headless dry-run exited 0"
assert_not_contains "$out1" "unknown arg" "--no-mesh/--dry-run accepted"
assert_not_contains "$out1" "no-mesh: refusing" "headless foundation-only does not hit membership deny"

# --- --bundle languages/php adds php, still excludes personal ---
home2="$TMP/home-bundle"
mkdir -p "$home2"
rc2=0
out2="$(
    HOME="$home2" \
    XDG_CONFIG_HOME="$home2/.config" \
    XDG_STATE_HOME="$home2/.local/state" \
    NON_INTERACTIVE=1 \
    bash "$SETUP" --no-mesh --non-interactive --dry-run --bundle languages/php 2>&1
)" || rc2=$?

sel2="$home2/.config/mesh/selections.list"
assert_file_exists "$sel2" "--bundle path persists selections.list"
body2="$(grep -vE '^[[:space:]]*(#|$)' "$sel2" | sort || true)"
assert_contains "$body2" "foundation/base" "--bundle list includes foundation/base"
assert_contains "$body2" "languages/php" "--bundle list includes languages/php"
assert_not_contains "$body2" "personal/" "--bundle list excludes personal"
assert_not_contains "$body2" "identity/" "--bundle list excludes identity"
assert_eq "$rc2" "0" "--bundle no-mesh dry-run exited 0"
assert_not_contains "$out2" "unknown arg" "--bundle accepted by setup.sh"

# Unflagged emit_default_selections still includes personal (list-bundles path).
unflagged=""
unflagged=$(bash "$SETUP" --list-bundles 2>&1) || true
assert_contains "$unflagged" "personal/personal" "unflagged catalog still lists personal"

summary
