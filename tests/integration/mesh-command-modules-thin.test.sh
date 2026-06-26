#!/usr/bin/env bash
# tests/integration/mesh-command-modules-thin.test.sh
#
# T2.1 contract: thin built-ins are real source-pure command modules, not
# dispatcher-maintained registrations.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
MESH="$REPO_ROOT/bin/mesh"

# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-command-modules-thin.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

MESH_HOME_FAKE="$SANDBOX/scripts"
IDENTITY_EMPTY="$SANDBOX/identity-empty"
mkdir -p \
    "$MESH_HOME_FAKE/lib" \
    "$MESH_HOME_FAKE/internal" \
    "$MESH_HOME_FAKE/runners" \
    "$IDENTITY_EMPTY"
ln -s "$REPO_ROOT/scripts/lib/mesh-command.sh" "$MESH_HOME_FAKE/lib/mesh-command.sh"

write_stub() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'SH'
#!/usr/bin/env bash
printf 'STUB:%s:%s\n' "${0##*/}" "$*"
SH
    chmod +x "$path"
}

write_stub "$MESH_HOME_FAKE/internal/mesh-status"
write_stub "$MESH_HOME_FAKE/internal/mesh-snap"
write_stub "$MESH_HOME_FAKE/lib/init.sh"
write_stub "$MESH_HOME_FAKE/lib/template-check.sh"
write_stub "$MESH_HOME_FAKE/lib/lint.sh"
write_stub "$MESH_HOME_FAKE/lib/catalog.sh"
write_stub "$MESH_HOME_FAKE/lib/personal-clone.sh"
write_stub "$MESH_HOME_FAKE/lib/secret.sh"
write_stub "$MESH_HOME_FAKE/runners/clean.sh"
write_stub "$MESH_HOME_FAKE/runners/upgrade.sh"
write_stub "$MESH_HOME_FAKE/runners/config.sh"

run_mesh() {
    MESH_HOME="$MESH_HOME_FAKE" \
    MESH_IDENTITY_DIR="$IDENTITY_EMPTY" \
    "$MESH" "$@"
}

thin_commands="status snap init template-check lint catalog personal-clone secret clean upgrade config"

echo "module files"
for name in $thin_commands; do
    module="$REPO_ROOT/scripts/commands/$name.sh"
    assert_file_exists "$module" "module exists for $name"
    assert_file_contains "$module" "mesh_register_command" "module registers $name"
    assert_file_contains "$module" "origin core" "module registers $name as origin core"
done

echo
echo "source-pure registration"
source_check="$(
    REPO_ROOT="$REPO_ROOT" bash <<'SH'
set -uo pipefail
source "$REPO_ROOT/scripts/lib/mesh-command.sh"
_mesh_fanout_validate_any() { :; }
for module in \
    status snap init template-check lint catalog personal-clone secret clean upgrade config
do
    # shellcheck disable=SC1090
    source "$REPO_ROOT/scripts/commands/$module.sh"
done
mesh_command_emit_tsv --internal
SH
)"
for name in $thin_commands; do
    count="$(printf '%s\n' "$source_check" | awk -F '\t' -v n="$name" '$1 == n { c++ } END { print c + 0 }')"
    assert_eq "$count" "1" "source registers $name exactly once"
    row="$(printf '%s\n' "$source_check" | awk -F '\t' -v n="$name" '$1 == n { print }')"
    assert_contains "$row" $'\tcore\tcore\tpublic\t' "$name metadata is public core/core"
done

echo
echo "dispatch through modules"
out="$(run_mesh status crc --json 2>&1)"
rc=$?
assert_eq "$rc" 0 "status module exits 0"
assert_eq "$out" "STUB:mesh-status:--detail crc --json" "status preserves positional alias mapping"

out="$(run_mesh --json 2>&1)"
rc=$?
assert_eq "$rc" 0 "top-level status flag exits 0"
assert_eq "$out" "STUB:mesh-status:--json" "top-level status flag uses registered status module"

out="$(run_mesh snap --quiet 2>&1)"
rc=$?
assert_eq "$rc" 0 "snap module exits 0"
assert_eq "$out" "STUB:mesh-snap:--quiet" "snap delegates to mesh-snap"

out="$(run_mesh init --help 2>&1)"
assert_eq "$out" "STUB:init.sh:--help" "init delegates to lib/init.sh"

out="$(run_mesh template-check --quiet 2>&1)"
assert_eq "$out" "STUB:template-check.sh:--quiet" "template-check delegates to lib/template-check.sh"

out="$(run_mesh lint 2>&1)"
assert_eq "$out" "STUB:lint.sh:" "lint delegates to lib/lint.sh"

out="$(run_mesh lint --json 2>&1)"
assert_eq "$out" "STUB:lint.sh:--json" "lint non-help args delegate to lib/lint.sh"

out="$(run_mesh lint --help 2>&1)"
rc=$?
assert_eq "$rc" 0 "lint --help exits 0"
assert_contains "$out" "Usage: mesh lint" "lint --help prints command help"
assert_not_contains "$out" "STUB:lint.sh" "lint --help does not run lint orchestrator"

out="$(run_mesh lint -h 2>&1)"
rc=$?
assert_eq "$rc" 0 "lint -h exits 0"
assert_contains "$out" "Usage: mesh lint" "lint -h prints command help"
assert_not_contains "$out" "STUB:lint.sh" "lint -h does not run lint orchestrator"

out="$(run_mesh catalog generate 2>&1)"
assert_eq "$out" "STUB:catalog.sh:" "catalog generate delegates to lib/catalog.sh"

out="$(run_mesh personal-clone --dry-run 2>&1)"
assert_eq "$out" "STUB:personal-clone.sh:--dry-run" "personal-clone delegates to lib/personal-clone.sh"

out="$(run_mesh secret list 2>&1)"
assert_eq "$out" "STUB:secret.sh:list" "secret delegates to lib/secret.sh"

out="$(run_mesh clean --apply 2>&1)"
assert_eq "$out" "STUB:clean.sh:--apply" "clean delegates to runners/clean.sh"

out="$(run_mesh upgrade --dry-run 2>&1)"
assert_eq "$out" "STUB:upgrade.sh:--dry-run" "upgrade delegates to runners/upgrade.sh"

out="$(run_mesh config list git 2>&1)"
assert_eq "$out" "STUB:config.sh:list git" "config delegates to runners/config.sh"

echo
echo "registry surface"
commands_out="$(run_mesh __commands --internal 2>&1)"
for name in $thin_commands; do
    count="$(printf '%s\n' "$commands_out" | awk -F '\t' -v n="$name" '$1 == n { c++ } END { print c + 0 }')"
    assert_eq "$count" "1" "runtime registry emits one $name row"
done

echo
summary
