#!/usr/bin/env bash
# Unit coverage for mesh-run fanout helpers used by syncthing/services:
#   - fanout env providers emit validated KEY=VALUE records
#   - remote command rendering carries those records into the SSH command
#   - syncthing's validator still rejects unsafe verbs before host/ssh work
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
MESH="$WS/bin/mesh"

# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-run-syncthing.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/home" "$SANDBOX/identity-empty"

_die() {
    printf 'mesh: %s\n' "$*" >&2
    exit 1
}

extract() {
    awk "/^$1\\(\\) \\{/{c=1} c{print} c&&/^}/{exit}" "$MESH"
}

eval "$(extract _mesh_quote_args)"
eval "$(extract _mesh_fanout_validate_syncthing)"
eval "$(extract _mesh_fanout_env_noninteractive)"
eval "$(extract _mesh_collect_fanout_env)"
eval "$(extract _mesh_env_records_to_remote_prefix)"
eval "$(extract _mesh_remote_command)"

echo "fanout env helpers"
out="$(_mesh_fanout_env_noninteractive 2>&1)"
rc=$?
assert_eq "$rc" 0 "noninteractive env provider exits 0"
assert_eq "$out" "NON_INTERACTIVE=1" "noninteractive env provider emits one KEY=VALUE record"

out="$(_mesh_collect_fanout_env _mesh_fanout_env_noninteractive 2>&1)"
rc=$?
assert_eq "$rc" 0 "env collector accepts valid provider output"
assert_eq "$out" "NON_INTERACTIVE=1" "env collector preserves provider record"

bad_provider() {
    printf 'BAD RECORD\n'
}
out="$(_mesh_collect_fanout_env bad_provider 2>&1)"
rc=$?
assert_ne "$rc" 0 "env collector rejects malformed provider output"
assert_contains "$out" "malformed record" "env collector names malformed fanout env records"

echo
echo "remote command rendering"
st_cmd="$(_mesh_remote_command "NON_INTERACTIVE=1" syncthing pair)"
assert_contains "$st_cmd" "NON_INTERACTIVE=1; export NON_INTERACTIVE;" \
    "remote syncthing command exports NON_INTERACTIVE"
assert_contains "$st_cmd" "mesh syncthing pair" \
    "remote syncthing command invokes mesh syncthing pair"

status_cmd="$(_mesh_remote_command "" status --write)"
assert_not_contains "$status_cmd" "NON_INTERACTIVE=1" \
    "remote status command has no noninteractive export"
assert_contains "$status_cmd" "mesh status --write" \
    "remote status command invokes mesh status --write"

echo
echo "syncthing validator"
out="$(_mesh_fanout_validate_syncthing pair 2>&1)"
rc=$?
assert_eq "$rc" 0 "syncthing pair validates"

out="$(_mesh_fanout_validate_syncthing status 2>&1)"
rc=$?
assert_eq "$rc" 0 "syncthing status validates"

out="$(_mesh_fanout_validate_syncthing password 2>&1)"
rc=$?
assert_ne "$rc" 0 "syncthing password is rejected"
assert_contains "$out" "only \`syncthing pair\` and \`syncthing status\` can fan out" \
    "syncthing rejection names safe verbs"

echo
echo "mesh run integration smoke"
run_mesh() {
    HOME="$SANDBOX/home" \
    MESH_IDENTITY_DIR="$SANDBOX/identity-empty" \
    bash "$MESH" "$@"
}

out="$(run_mesh run --all syncthing password 2>&1)"
rc=$?
assert_ne "$rc" 0 "mesh run rejects syncthing password before host work"
assert_contains "$out" "can fan out" "mesh run rejection includes fanout wording"

out="$(run_mesh run --hosts mac --dry-run syncthing pair 2>&1)"
rc=$?
assert_eq "$rc" 0 "mesh run accepts syncthing pair in dry-run mode"
assert_contains "$out" "syncthing pair" "dry-run shows the fanout command"

echo
summary
