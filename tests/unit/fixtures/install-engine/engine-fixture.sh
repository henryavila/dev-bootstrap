#!/usr/bin/env bash
# engine-fixture.sh — minimal install-engine emulating C17 lifecycle for ONE custom item.
#
# Args: <phase> <script-path>
#   phase ∈ {check, install, verify, rollback}
#
# Pre-sources helpers + drivers in main shell, then runs the requested phase
# in a subshell that ALSO sources the custom script (per spec §C18 contract).
#
# Exit code = phase exit code.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PHASE="${1:?phase required}"
SCRIPT="${2:?script path required}"

# 1. Engine sources helpers + ALL drivers eagerly (P3 confirmed cost is negligible).
# shellcheck source=helpers/log.sh
. "$HERE/helpers/log.sh"
# shellcheck source=helpers/env.sh
. "$HERE/helpers/env.sh"
for d in "$HERE/drivers/"*.sh; do
    # shellcheck disable=SC1090
    . "$d"
done

# 2. Validate the custom script defines required functions.
#    Lint L9 enforces this statically; runtime validation here is belt+suspenders.
#    H-3 fix (checkpoint-2): subshell uses `set -euo pipefail` so top-level
#    errors during sourcing abort here instead of being silently swallowed
#    while check/install end up defined. Source rc is explicitly captured.
(
    set -euo pipefail
    # shellcheck disable=SC1090
    if ! . "$SCRIPT"; then
        err "source failed for $SCRIPT"
        exit 3
    fi
    if [ "$(type -t check)" != "function" ]; then
        err "custom script missing required check() function"
        exit 2
    fi
    if [ "$(type -t install)" != "function" ]; then
        err "custom script missing required install() function"
        exit 2
    fi
) || exit $?

# 3. Capture engine-scope baseline BEFORE running the custom script's subshell.
#    H-1 fix (checkpoint-2): leak detection is GENERIC (compgen diff) — works
#    for any custom script + catches variable leaks the old hardcoded check ignored.
#    CX-M5 fix (checkpoint-3): also hash the VALUES/BODIES of engine-owned
#    symbols. A stealth mutation could clean up new names (defeating compgen
#    diff) while mutating an EXISTING symbol (e.g. MESH_OS, or redefining a
#    driver). The hash diff catches body/value drift on symbols that survive
#    pre→post. We hash an explicit list — using `declare -p` wholesale would
#    capture bash auto-vars (LINENO, SECONDS, PIPESTATUS, …) that change every
#    line of execution and would produce false positives.
#
#    Add new helpers/drivers' symbols here when extending. The list is the
#    contract: these symbols must survive the subshell unchanged.
MESH_OWNED_FNS_LIST="info warn err install_brew install_apt"
MESH_OWNED_VARS_LIST="MESH_OS MESH_STATE_FILE HERE PHASE SCRIPT"
__BL_FNS=$(compgen -A function 2>/dev/null | sort)
__BL_VARS=$(compgen -v 2>/dev/null | sort)
__BL_OWNED_FN_HASH=$(declare -f $MESH_OWNED_FNS_LIST 2>/dev/null | cksum)
__BL_OWNED_VAR_HASH=$(
    for v in $MESH_OWNED_VARS_LIST; do
        printf '%s=%s\n' "$v" "${!v-__UNSET__}"
    done | cksum
)

# 4. Run requested phase in subshell isolation.
#    CX-M4 fix (checkpoint-3): verify() falls back to check() when the custom
#    script doesn't define verify (spec §C17/§C18: verify is optional and
#    the engine's default fallback is to re-run check to confirm install).
#    rollback() is no-op when absent (also per spec — explicit rollback is
#    only required when install does something check() can't reverse via
#    re-run). The base `( . "$SCRIPT"; "$PHASE" )` form is preserved for
#    check/install so existing mutation harnesses keep matching it.
case "$PHASE" in
    verify)
        ( . "$SCRIPT"
          if [ "$(type -t verify)" = "function" ]; then
              verify
          else
              check
          fi )
        ;;
    rollback)
        ( . "$SCRIPT"
          if [ "$(type -t rollback)" = "function" ]; then
              rollback
          else
              : # optional rollback — no-op when absent
          fi )
        ;;
    *)
        ( . "$SCRIPT"; "$PHASE" )
        ;;
esac
phase_rc=$?

# 5. Post-phase isolation check.
#    Three layers, increasingly strict:
#    a) compgen name diff — catches new function or variable names that leaked
#       (parens-removed or stealth-with-vars).
#    b) hash diff over engine-owned symbol VALUES/BODIES — catches mutations of
#       EXISTING symbols (e.g. `MESH_OS="..."` outside subshell with cleanup).
#       The name diff misses this because MESH_OS already exists in baseline.
__POST_FNS=$(compgen -A function 2>/dev/null | sort)
__POST_VARS=$(compgen -v 2>/dev/null | sort)
__POST_OWNED_FN_HASH=$(declare -f $MESH_OWNED_FNS_LIST 2>/dev/null | cksum)
__POST_OWNED_VAR_HASH=$(
    for v in $MESH_OWNED_VARS_LIST; do
        printf '%s=%s\n' "$v" "${!v-__UNSET__}"
    done | cksum
)
fn_leaks=$(comm -13 <(echo "$__BL_FNS") <(echo "$__POST_FNS"))
var_leaks=$(comm -13 <(echo "$__BL_VARS") <(echo "$__POST_VARS") \
    | grep -Ev '^(__BL_FNS|__BL_VARS|__BL_OWNED_FN_HASH|__BL_OWNED_VAR_HASH|__POST_FNS|__POST_VARS|__POST_OWNED_FN_HASH|__POST_OWNED_VAR_HASH|MESH_OWNED_FNS_LIST|MESH_OWNED_VARS_LIST|phase_rc|fn_leaks|var_leaks|leak_count|v)$' \
    || true)

leak_count=0
if [ -n "$fn_leaks" ]; then
    while IFS= read -r fn; do
        [ -z "$fn" ] && continue
        err "ISOLATION FAILURE: function '$fn' leaked into engine scope"
        leak_count=$((leak_count + 1))
    done <<EOF
$fn_leaks
EOF
fi
if [ -n "$var_leaks" ]; then
    while IFS= read -r var; do
        [ -z "$var" ] && continue
        err "ISOLATION FAILURE: variable '$var' leaked into engine scope"
        leak_count=$((leak_count + 1))
    done <<EOF
$var_leaks
EOF
fi
# CX-M5 (checkpoint-3): even when no new symbols leak, an EXISTING engine
# symbol may have been mutated. Compare hashes of engine-owned-only symbols
# (explicit list to avoid bash auto-var noise in declare -p).
if [ "$__BL_OWNED_FN_HASH" != "$__POST_OWNED_FN_HASH" ]; then
    err "ISOLATION FAILURE: engine-owned function body mutated ($MESH_OWNED_FNS_LIST)"
    leak_count=$((leak_count + 1))
fi
if [ "$__BL_OWNED_VAR_HASH" != "$__POST_OWNED_VAR_HASH" ]; then
    err "ISOLATION FAILURE: engine-owned variable value mutated ($MESH_OWNED_VARS_LIST)"
    leak_count=$((leak_count + 1))
fi
if [ "$leak_count" -gt 0 ]; then
    exit 64
fi
exit "$phase_rc"
