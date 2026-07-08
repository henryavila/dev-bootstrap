#!/usr/bin/env bash
# tests/integration/mesh-command-modules-services.test.sh
#
# T2.2 contract for services/syncthing command modules.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
MESH="$REPO_ROOT/bin/mesh"

# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-command-modules-services.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

MESH_HOME_FAKE="$SANDBOX/scripts"
IDENTITY_EMPTY="$SANDBOX/identity-empty"
mkdir -p "$MESH_HOME_FAKE/lib" "$MESH_HOME_FAKE/runners" "$IDENTITY_EMPTY"
ln -s "$REPO_ROOT/scripts/lib/mesh-command.sh" "$MESH_HOME_FAKE/lib/mesh-command.sh"

cat > "$MESH_HOME_FAKE/runners/services.sh" <<'SH'
#!/usr/bin/env bash
printf 'SERVICES:%s:alias=%s\n' "$*" "${MESH_SERVICES_ALIAS:-}"
SH
chmod +x "$MESH_HOME_FAKE/runners/services.sh"

cat > "$MESH_HOME_FAKE/runners/syncthing.sh" <<'SH'
#!/usr/bin/env bash
printf 'SYNCTHING:%s\n' "$*"
SH
chmod +x "$MESH_HOME_FAKE/runners/syncthing.sh"

run_mesh() {
    HOME="$SANDBOX/home" \
    MESH_HOME="$MESH_HOME_FAKE" \
    MESH_IDENTITY_DIR="$IDENTITY_EMPTY" \
    MESH_RUN_SELF_ALIAS=mac \
    "$MESH" "$@"
}

echo "module files"
for name in services syncthing; do
    module="$REPO_ROOT/scripts/commands/$name.sh"
    assert_file_exists "$module" "module exists for $name"
    assert_file_contains "$module" "mesh_register_command" "module registers $name"
    assert_file_contains "$module" "fanout allowed" "module marks $name fanout allowed"
done

echo
echo "source-pure registration"
source_check="$(
    REPO_ROOT="$REPO_ROOT" bash <<'SH'
set -uo pipefail
source "$REPO_ROOT/scripts/lib/mesh-command.sh"
_mesh_fanout_validate_syncthing() { :; }
_mesh_fanout_validate_services() { :; }
_mesh_fanout_env_noninteractive() { printf 'NON_INTERACTIVE=1\n'; }
source "$REPO_ROOT/scripts/commands/services.sh"
source "$REPO_ROOT/scripts/commands/syncthing.sh"
mesh_command_emit_tsv --internal
SH
)"
for name in services syncthing; do
    count="$(printf '%s\n' "$source_check" | awk -F '\t' -v n="$name" '$1 == n { c++ } END { print c + 0 }')"
    assert_eq "$count" "1" "source registers $name exactly once"
    row="$(printf '%s\n' "$source_check" | awk -F '\t' -v n="$name" '$1 == n { print }')"
    assert_contains "$row" $'\tcore\tcore\tpublic\tallowed' "$name metadata is public core/core fanout allowed"
done

echo
echo "dispatch"
out="$(run_mesh services status mysql 2>&1)"
rc=$?
assert_eq "$rc" 0 "services module exits 0"
assert_eq "$out" "SERVICES:status mysql:alias=mac" "services delegates to runner with resolved alias"

out="$(run_mesh syncthing pair 2>&1)"
rc=$?
assert_eq "$rc" 0 "syncthing module exits 0"
assert_eq "$out" "SYNCTHING:pair" "syncthing delegates to runner"

echo
echo "fanout policy"
out="$(run_mesh run --all services bogus 2>&1)"
rc=$?
assert_ne "$rc" 0 "services fanout rejects unsupported subverb"
assert_contains "$out" "services can only fan out" "services fanout rejection names allowlist"

out="$(run_mesh run --all syncthing password 2>&1)"
rc=$?
assert_ne "$rc" 0 "syncthing fanout rejects unsafe verb"
assert_contains "$out" "only \`syncthing pair\` and \`syncthing status\` can fan out" \
    "syncthing fanout rejection names safe verbs"

commands_out="$(run_mesh __commands --internal 2>&1)"
assert_contains "$commands_out" $'services\tControl mesh-owned daemons\tcore\tcore\tpublic\tallowed' \
    "services appears once in __commands with fanout allowed"
assert_contains "$commands_out" $'syncthing\tPair this node into the Syncthing mesh\tcore\tcore\tpublic\tallowed' \
    "syncthing appears once in __commands with fanout allowed"

echo
summary
