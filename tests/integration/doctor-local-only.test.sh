#!/usr/bin/env bash
# tests/integration/doctor-local-only.test.sh
#
# Doctor contract for identity config that exists only on the local machine:
# uncommitted config changes and commits ahead of upstream are not replicated.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$SELF_DIR/../lib/assert.sh"

DOCTOR="$REPO_ROOT/scripts/runners/doctor.sh"
SANDBOX="$(mktemp -d -t mesh-doctor-local.XXXXXX)"
trap '[[ -d "$SANDBOX" ]] && rm -rf "$SANDBOX"' EXIT

HOME_SANDBOX="$SANDBOX/home"
ID="$SANDBOX/identity"
REMOTE="$SANDBOX/remote.git"
mkdir -p "$HOME_SANDBOX" "$ID/shell"
git init -q --bare "$REMOTE"
git -C "$ID" init -q
git -C "$ID" config user.name "Mesh Test"
git -C "$ID" config user.email "mesh@example.test"
git -C "$ID" remote add origin "$REMOTE"
printf '# empty deploy map\n' > "$ID/deploy.map"
printf 'mesh-identity|~/mesh-identity\n' > "$ID/shell/ai-pinned.list"
git -C "$ID" add deploy.map shell/ai-pinned.list
git -C "$ID" commit -qm "init identity"
git -C "$ID" branch -M main
git -C "$ID" push -q -u origin main

run_doctor() {
    HOME="$HOME_SANDBOX" \
        MESH_IDENTITY_DIR="$ID" \
        DOCTOR_LAUNCHD_DIR="$SANDBOX/no-launchd" \
        EBM_BREW_PREFIX_OVERRIDE="/usr/local" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$DOCTOR" "$@"
}

echo "── clean identity repo ──"
CLEAN_OUT="$(run_doctor --quiet 2>&1)"
assert_eq "$?" "0" "clean identity exits 0"
assert_not_contains "$CLEAN_OUT" "Local-only identity config" "clean identity has no local-only warning"

echo "── uncommitted identity config ──"
printf 'Keyboard Maestro|/tmp/km\n' >> "$ID/shell/ai-pinned.list"
DIRTY_OUT="$(run_doctor --quiet 2>&1)"
DIRTY_RC=$?
assert_eq "$DIRTY_RC" "1" "uncommitted identity config makes doctor non-zero"
assert_contains "$DIRTY_OUT" "Local-only identity config" "doctor labels local-only config"
assert_contains "$DIRTY_OUT" "uncommitted: shell/ai-pinned.list" "doctor names the dirty config file"

echo "── unpushed identity commit ──"
git -C "$ID" add shell/ai-pinned.list
git -C "$ID" commit -qm "pin Keyboard Maestro"
AHEAD_OUT="$(run_doctor --json 2>&1)"
AHEAD_RC=$?
assert_eq "$AHEAD_RC" "1" "unpushed identity commit makes doctor non-zero"
assert_contains "$AHEAD_OUT" '"local_only":1' "json reports one local-only issue"
assert_contains "$AHEAD_OUT" '"unpushed: 1 commit(s) ahead of upstream"' "json names the unpushed commit state"

summary
