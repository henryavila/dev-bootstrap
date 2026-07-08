#!/usr/bin/env bash
# tests/integration/mesh-command-modules-menu-topic.test.sh
#
# T2.2 contract for menu/topic command modules.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
MESH="$REPO_ROOT/bin/mesh"

# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-command-modules-menu-topic.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

MESH_HOME_FAKE="$SANDBOX/scripts"
IDENTITY_EMPTY="$SANDBOX/identity-empty"
WS_FAKE="$SANDBOX/workstation"
mkdir -p "$MESH_HOME_FAKE/lib" "$MESH_HOME_FAKE/runners" "$IDENTITY_EMPTY" "$WS_FAKE/topics"
ln -s "$REPO_ROOT/scripts/lib/mesh-command.sh" "$MESH_HOME_FAKE/lib/mesh-command.sh"

cat > "$MESH_HOME_FAKE/runners/menu.sh" <<'SH'
#!/usr/bin/env bash
printf 'MENU:%s\n' "$*"
SH
chmod +x "$MESH_HOME_FAKE/runners/menu.sh"

cat > "$MESH_HOME_FAKE/runners/auto-update.sh" <<'SH'
#!/usr/bin/env bash
printf 'AUTO_UPDATE:%s:ONLY_TOPICS=%s:REQUIRE=%s\n' "$*" "${ONLY_TOPICS:-}" "${DEV_BOOTSTRAP_REQUIRE_ONLY_TOPICS:-}"
SH
chmod +x "$MESH_HOME_FAKE/runners/auto-update.sh"

cat > "$WS_FAKE/setup.sh" <<'SH'
#!/usr/bin/env bash
printf 'SETUP:%s\n' "$*"
SH
chmod +x "$WS_FAKE/setup.sh"

run_mesh() {
    HOME="$SANDBOX/home" \
    MESH_HOME="$MESH_HOME_FAKE" \
    MESH_IDENTITY_DIR="$IDENTITY_EMPTY" \
    MESH_WORKSTATION_DIR="$WS_FAKE" \
    "$MESH" "$@"
}

echo "module files"
for name in menu topic; do
    module="$REPO_ROOT/scripts/commands/$name.sh"
    assert_file_exists "$module" "module exists for $name"
    assert_file_contains "$module" "mesh_register_command" "module registers $name"
    assert_file_contains "$module" "fanout none" "module marks $name fanout none"
done

echo
echo "source-pure registration"
source_check="$(
    REPO_ROOT="$REPO_ROOT" bash <<'SH'
set -uo pipefail
source "$REPO_ROOT/scripts/lib/mesh-command.sh"
source "$REPO_ROOT/scripts/commands/menu.sh"
source "$REPO_ROOT/scripts/commands/topic.sh"
mesh_command_emit_tsv --internal
SH
)"
for name in menu topic; do
    count="$(printf '%s\n' "$source_check" | awk -F '\t' -v n="$name" '$1 == n { c++ } END { print c + 0 }')"
    assert_eq "$count" "1" "source registers $name exactly once"
    row="$(printf '%s\n' "$source_check" | awk -F '\t' -v n="$name" '$1 == n { print }')"
    assert_contains "$row" $'\tcore\tcore\tpublic\tnone' "$name metadata is public core/core fanout none"
done

echo
echo "menu dispatch"
out="$(run_mesh menu -h 2>&1)"
rc=$?
assert_eq "$rc" 0 "menu help exits 0"
assert_contains "$out" "Usage: mesh menu [--apply]" "menu help is served by module"
assert_not_contains "$out" "MENU:" "menu help does not execute runner"

out="$(run_mesh menu --apply 2>&1)"
rc=$?
assert_eq "$rc" 0 "menu --apply exits 0"
assert_eq "$out" "MENU:--apply" "menu --apply delegates to runner"

echo
echo "topic dispatch"
out="$(run_mesh topic -h 2>&1)"
rc=$?
assert_eq "$rc" 0 "topic help exits 0"
assert_contains "$out" "mesh topic list" "topic help prints list usage"

out="$(run_mesh topic list 2>&1)"
rc=$?
assert_eq "$rc" 0 "topic list exits 0"
assert_eq "$out" "SETUP:--list-bundles" "topic list delegates to setup.sh --list-bundles"

out="$(run_mesh topic 20,30 shell-terminal 2>&1)"
rc=$?
assert_eq "$rc" 0 "topic apply exits 0"
assert_contains "$out" "AUTO_UPDATE:--only mesh-workstation --full" \
    "topic apply delegates through update --only mesh-workstation --full"
assert_contains "$out" "ONLY_TOPICS=20 30 shell-terminal" \
    "topic apply normalizes comma-separated topics"
assert_contains "$out" "REQUIRE=1" "topic apply preserves require-only-topics guard"

out="$(run_mesh topic list extra 2>&1)"
rc=$?
assert_ne "$rc" 0 "topic list rejects extra args"
assert_contains "$out" "topic list: unexpected arg 'extra'" "topic list rejection names extra arg"

commands_out="$(run_mesh __commands --internal 2>&1)"
assert_contains "$commands_out" $'menu\tOpen the interactive item selector\tcore\tcore\tpublic\tnone' \
    "menu appears once in __commands"
assert_contains "$commands_out" $'topic\tList or apply mesh topics\tcore\tcore\tpublic\tnone' \
    "topic appears once in __commands"

echo
summary
