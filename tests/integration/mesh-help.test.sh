#!/usr/bin/env bash
# tests/integration/mesh-help.test.sh
#
# Contract for registry-derived mesh help:
#   - top-level help lists exactly the public commands from `mesh __commands`
#   - hidden/internal commands are omitted
#   - registered public commands expose non-mutating help
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
MESH="$REPO_ROOT/bin/mesh"

# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-help.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

MESH_HOME_FAKE="$SANDBOX/scripts"
IDENTITY_EMPTY="$SANDBOX/identity-empty"
MODULES="$SANDBOX/modules"
mkdir -p \
    "$MESH_HOME_FAKE/lib" \
    "$MESH_HOME_FAKE/internal" \
    "$MESH_HOME_FAKE/runners" \
    "$IDENTITY_EMPTY" \
    "$MODULES"
ln -s "$REPO_ROOT/scripts/lib/mesh-command.sh" "$MESH_HOME_FAKE/lib/mesh-command.sh"

write_stub() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    -h|--help)
        printf 'HELP:%s\n' "$(basename "$0")"
        exit 0
        ;;
    *)
        printf 'RUN:%s:%s\n' "$(basename "$0")" "$*"
        exit 0
        ;;
esac
SH
    chmod +x "$path"
}

write_stub "$MESH_HOME_FAKE/internal/mesh-status"
write_stub "$MESH_HOME_FAKE/internal/mesh-snap"
write_stub "$MESH_HOME_FAKE/runners/auto-update.sh"
write_stub "$MESH_HOME_FAKE/runners/doctor.sh"
write_stub "$MESH_HOME_FAKE/runners/syncthing.sh"
write_stub "$MESH_HOME_FAKE/runners/menu.sh"
write_stub "$MESH_HOME_FAKE/runners/clean.sh"
write_stub "$MESH_HOME_FAKE/runners/upgrade.sh"
write_stub "$MESH_HOME_FAKE/runners/ia.sh"
write_stub "$MESH_HOME_FAKE/runners/config.sh"
write_stub "$MESH_HOME_FAKE/runners/services.sh"
write_stub "$MESH_HOME_FAKE/lib/init.sh"
write_stub "$MESH_HOME_FAKE/lib/template-check.sh"
write_stub "$MESH_HOME_FAKE/lib/lint.sh"
write_stub "$MESH_HOME_FAKE/lib/catalog.sh"
write_stub "$MESH_HOME_FAKE/lib/personal-clone.sh"
write_stub "$MESH_HOME_FAKE/lib/secret.sh"

cat > "$MODULES/10-extra.sh" <<'SH'
cmd_hidden() { :; }
cmd_internal() { :; }
cmd_zeta_public() {
    case "${1:-}" in
        -h|--help) printf 'HELP:zeta-public\n' ;;
        *) : ;;
    esac
}

mesh_register_command \
    --name hidden-cmd \
    --summary "Hidden command" \
    --group zeta \
    --origin core \
    --visibility hidden \
    --fanout none \
    --handler cmd_hidden

mesh_register_command \
    --name internal-cmd \
    --summary "Internal command" \
    --group alpha \
    --origin core \
    --visibility internal \
    --fanout none \
    --handler cmd_internal

mesh_register_command \
    --name zeta-public \
    --summary "Zeta public command" \
    --group zeta \
    --origin core \
    --visibility public \
    --fanout allowed \
    --handler cmd_zeta_public
SH

run_mesh() {
    MESH_HOME="$MESH_HOME_FAKE" \
    MESH_IDENTITY_DIR="$IDENTITY_EMPTY" \
    MESH_COMMAND_MODULE_DIR="$MODULES" \
    "$MESH" "$@"
}

public_command_names() {
    awk -F '\t' '{ print $1 }'
}

help_command_names() {
    awk '
        /^Commands:$/ { in_commands = 1; next }
        in_commands && /^$/ { exit }
        in_commands && /^  [a-z][a-z0-9-]+[[:space:]]/ { print $1 }
    '
}

echo "top-level help derives command list from registry"
commands_out="$(run_mesh __commands 2>&1)"
rc=$?
assert_eq "$rc" 0 "__commands exits 0"

help_out="$(run_mesh --help 2>&1)"
rc=$?
assert_eq "$rc" 0 "mesh --help exits 0"

expected_names="$(printf '%s\n' "$commands_out" | public_command_names)"
actual_names="$(printf '%s\n' "$help_out" | help_command_names)"
assert_eq "$actual_names" "$expected_names" "help command table matches public __commands names"
assert_contains "$help_out" "zeta-public" "help includes public module command"
assert_not_contains "$help_out" "hidden-cmd" "help omits hidden module command"
assert_not_contains "$help_out" "internal-cmd" "help omits internal module command"
assert_not_contains "$help_out" "__commands" "help omits internal producer command"

echo
echo "registered public commands expose help"
while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    out="$(run_mesh "$name" -h 2>&1)"
    rc=$?
    assert_eq "$rc" 0 "mesh $name -h exits 0"
    if [[ -n "$out" ]]; then
        pass "mesh $name -h prints help output"
    else
        fail "mesh $name -h prints help output"
    fi
done <<<"$expected_names"

out="$(run_mesh config --help 2>&1)"
rc=$?
assert_eq "$rc" 0 "mesh config --help exits 0"
assert_contains "$out" "HELP:config.sh" "mesh config --help delegates to safe runner help"
assert_not_contains "$out" "RUN:config.sh" "mesh config --help does not execute config action"

echo
summary
