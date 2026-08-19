#!/usr/bin/env bash
# F3 T-002 — without MESH_NO_MESH the default catalog still requires
# personal/personal and identity/identity; F0–F2 no-mesh tests still pass.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

SETUP="$WS/setup.sh"
INIT_TS="$WS/scripts/menu/src/core/init.ts"

assert_file_exists "$SETUP" "setup.sh exists"
assert_file_exists "$INIT_TS" "init.ts exists"

# Unflagged --list-bundles still shows personal + identity as required.
unflagged=""
unflagged_rc=0
unflagged=$(bash "$SETUP" --list-bundles 2>&1) || unflagged_rc=$?
assert_eq "$unflagged_rc" "0" "unflagged --list-bundles exits 0"
assert_contains "$unflagged" "personal/personal" "unflagged lists personal/personal"
assert_contains "$unflagged" "identity/identity" "unflagged lists identity/identity"

pers_line="$(printf '%s\n' "$unflagged" | grep -E '^personal/personal\b' || true)"
id_line="$(printf '%s\n' "$unflagged" | grep -E '^identity/identity\b' || true)"
assert_contains "$pers_line" "required" "personal/personal is marked required when unflagged"
assert_contains "$id_line" "required" "identity/identity is marked required when unflagged"

# Menu helpers: unflagged requiredKeys still include personal + identity.
menu_probe="$(
    cd "$WS/scripts/menu" && npx vitest run tests/no-mesh-menu.test.ts -t 'still locks personal' 2>&1
)" || menu_rc=$?
menu_rc="${menu_rc:-0}"
assert_eq "$menu_rc" "0" "unflagged menu requiredKeys test exits 0"
assert_contains "$menu_probe" "1 passed" \
    "vitest ran the unflagged required-locks case (1 passed)"

# init.ts must not demote required when MESH_NO_MESH is unset (guard: unlock
# helpers are gated on noMeshActive).
assert_file_contains "$INIT_TS" 'noMeshActive' \
    "init.ts gates unlocks on noMeshActive"
assert_file_contains "$INIT_TS" 'NO_MESH_UNLOCK_KEYS' \
    "init.ts documents the unlock list constant"

# Re-run F0–F2 no-mesh verifiers in the same process tree.
run_one() {
    local label="$1" cmd="$2" rc=0
    echo "── $label ──"
    if eval "$cmd"; then
        pass "$label exits 0"
    else
        rc=$?
        fail "$label exits $rc"
    fi
}

run_one "F0 membership-schema" "bash \"$WS/tests/unit/no-mesh-membership-schema.test.sh\""
run_one "F0 no-mesh-filter" "bash \"$WS/tests/unit/no-mesh-filter.test.sh\""
run_one "F1 no-mesh-menu (vitest)" "bash \"$WS/tests/unit/no-mesh-menu.test.sh\""
run_one "F1 headless-default" "bash \"$WS/tests/integration/no-mesh-headless-default.test.sh\""
run_one "F2 engine-deny" "bash \"$WS/tests/integration/no-mesh-engine-deny.test.sh\""
run_one "F2 atuin-login-no-mesh" "bash \"$WS/tests/unit/atuin-login-no-mesh.test.sh\""

summary
