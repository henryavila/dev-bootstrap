#!/usr/bin/env bash
# tests/integration/mesh-update-command-module.test.sh
#
# T3.1 contract: `mesh update` is a source-pure command module while preserving
# all parser behavior and auto-update motor invocation semantics.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
MESH="$REPO_ROOT/bin/mesh"

# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-update-command-module.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

MESH_HOME_FAKE="$SANDBOX/scripts"
IDENTITY_EMPTY="$SANDBOX/identity-empty"
mkdir -p "$MESH_HOME_FAKE/lib" "$MESH_HOME_FAKE/runners" "$IDENTITY_EMPTY"
ln -s "$REPO_ROOT/scripts/lib/mesh-command.sh" "$MESH_HOME_FAKE/lib/mesh-command.sh"

cat > "$MESH_HOME_FAKE/runners/auto-update.sh" <<'SH'
#!/usr/bin/env bash
printf 'AUTO_UPDATE:%s:ALIAS=%s:TMUX=%s:ONLY_TOPICS=%s:REQUIRE=%s\n' \
    "$*" \
    "${MESH_AUTOUPDATE_ALIAS:-}" \
    "${DEV_BOOTSTRAP_TMUX_AUTO_MAIN:-}" \
    "${ONLY_TOPICS:-}" \
    "${DEV_BOOTSTRAP_REQUIRE_ONLY_TOPICS:-}"
SH
chmod +x "$MESH_HOME_FAKE/runners/auto-update.sh"

run_mesh() {
    HOME="$SANDBOX/home" \
    MESH_HOME="$MESH_HOME_FAKE" \
    MESH_IDENTITY_DIR="$IDENTITY_EMPTY" \
    MESH_RUN_SELF_ALIAS=mac \
    "$MESH" "$@"
}

echo "module file"
module="$REPO_ROOT/scripts/commands/update.sh"
assert_file_exists "$module" "module exists for update"
assert_file_contains "$module" "mesh_register_command" "module registers update"
assert_file_contains "$module" "fanout allowed" "module marks update fanout allowed"
assert_file_contains "$module" "cmd_update_run" "module owns update handler"

echo
echo "source-pure registration"
source_check="$(
    REPO_ROOT="$REPO_ROOT" bash <<'SH'
set -uo pipefail
source "$REPO_ROOT/scripts/lib/mesh-command.sh"
_mesh_fanout_validate_update() { :; }
source "$REPO_ROOT/scripts/commands/update.sh"
mesh_command_emit_tsv --internal
SH
)"
count="$(printf '%s\n' "$source_check" | awk -F '\t' '$1 == "update" { c++ } END { print c + 0 }')"
assert_eq "$count" "1" "source registers update exactly once"
row="$(printf '%s\n' "$source_check" | awk -F '\t' '$1 == "update" { print }')"
assert_contains "$row" $'update\tPull and apply mesh updates\tcore\tcore\tpublic\tallowed' \
    "update metadata is public core/core fanout allowed"

direct_out="$(
    REPO_ROOT="$REPO_ROOT" MOTOR="$MESH_HOME_FAKE/runners/auto-update.sh" bash <<'SH'
set -uo pipefail
source "$REPO_ROOT/scripts/lib/mesh-command.sh"
_mesh_fanout_validate_update() { :; }
_mesh_self_alias() { printf 'direct'; }
_resolve_companion() { printf '%s\n' "$MOTOR"; }
_die() { printf '%s\n' "$*" >&2; exit 1; }
source "$REPO_ROOT/scripts/commands/update.sh"
cmd_update_run --topics 20,30 -t shell-terminal
SH
)"
assert_contains "$direct_out" "AUTO_UPDATE:--only mesh-workstation --full" \
    "direct-sourced update handler can invoke the motor without bin/mesh fallback"
assert_contains "$direct_out" "ALIAS=direct" "direct-sourced update handler resolves alias through injected core helper"
assert_contains "$direct_out" "ONLY_TOPICS=20 30 shell-terminal" \
    "direct-sourced update handler owns topic normalization"

echo
echo "dispatch"
out="$(run_mesh update --help 2>&1)"
rc=$?
assert_eq "$rc" 0 "update --help exits 0"
assert_eq "$out" "AUTO_UPDATE:--help:ALIAS=mac:TMUX=0:ONLY_TOPICS=:REQUIRE=" \
    "update --help delegates to auto-update help with update env"

out="$(run_mesh update -o workstation -f -i --dry-run 2>&1)"
rc=$?
assert_eq "$rc" 0 "update -o workstation -f -i exits 0"
assert_eq "$out" "AUTO_UPDATE:--only mesh-workstation --full --interactive --dry-run:ALIAS=mac:TMUX=0:ONLY_TOPICS=:REQUIRE=" \
    "update maps workstation alias and preserves full, interactive, passthrough args"

out="$(run_mesh update -o identity --verbose 2>&1)"
rc=$?
assert_eq "$rc" 0 "update -o identity exits 0"
assert_eq "$out" "AUTO_UPDATE:--only mesh-identity --verbose:ALIAS=mac:TMUX=0:ONLY_TOPICS=:REQUIRE=" \
    "update maps identity alias and preserves passthrough args"

out="$(run_mesh update -f 2>&1)"
rc=$?
assert_eq "$rc" 0 "update without -o exits 0"
assert_contains "$out" "AUTO_UPDATE:--only mesh-workstation --full:ALIAS=mac:TMUX=0" \
    "update without -o runs workstation first"
assert_contains "$out" "AUTO_UPDATE:--only mesh-identity --full:ALIAS=mac:TMUX=0" \
    "update without -o runs identity second"

out="$(run_mesh update --topics 20,30 -t shell-terminal 2>&1)"
rc=$?
assert_eq "$rc" 0 "update --topics exits 0"
assert_contains "$out" "AUTO_UPDATE:--only mesh-workstation --full" \
    "update --topics targets workstation and forces full when needed"
assert_contains "$out" "ONLY_TOPICS=20 30 shell-terminal" \
    "update --topics normalizes comma-separated and repeated topic args"
assert_contains "$out" "REQUIRE=1" "update --topics sets require-only-topics guard"

echo
echo "error handling"
out="$(run_mesh update -o 2>&1)"
rc=$?
assert_ne "$rc" 0 "update -o without value exits nonzero"
assert_contains "$out" "update: -o/--only requires a repo name" \
    "update -o without value names the missing repo"

out="$(run_mesh update --topics 20 -i 2>&1)"
rc=$?
assert_ne "$rc" 0 "update --topics -i exits nonzero"
assert_contains "$out" "update: --topics cannot be combined with -i/--interactive" \
    "update rejects interactive topic selection"

out="$(run_mesh update -o identity --topics 20 2>&1)"
rc=$?
assert_ne "$rc" 0 "update --topics identity exits nonzero"
assert_contains "$out" "update: --topics applies only to mesh-workstation" \
    "update rejects topic selection outside workstation"

out="$(run_mesh update bogus 2>&1)"
rc=$?
assert_ne "$rc" 0 "update unknown positional exits nonzero"
assert_contains "$out" "update: unknown arg 'bogus'" "update reports unknown positional arg"

echo
summary
