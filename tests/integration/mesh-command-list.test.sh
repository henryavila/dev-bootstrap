#!/usr/bin/env bash
# tests/integration/mesh-command-list.test.sh
#
# Contract for `mesh __commands`: stable TSV metadata from the registry.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
MESH="$REPO_ROOT/bin/mesh"

# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-command-list.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

MESH_HOME_FAKE="$SANDBOX/scripts"
IDENTITY_EMPTY="$SANDBOX/identity-empty"
MODULES="$SANDBOX/modules"
mkdir -p "$MESH_HOME_FAKE/lib" "$MESH_HOME_FAKE/internal" "$MESH_HOME_FAKE/runners" "$IDENTITY_EMPTY" "$MODULES"
ln -s "$REPO_ROOT/scripts/lib/mesh-command.sh" "$MESH_HOME_FAKE/lib/mesh-command.sh"

cat > "$MESH_HOME_FAKE/internal/mesh-status" <<'SH'
#!/usr/bin/env bash
printf 'STATUS:%s\n' "$*"
SH
chmod +x "$MESH_HOME_FAKE/internal/mesh-status"

cat > "$MESH_HOME_FAKE/runners/config.sh" <<'SH'
#!/usr/bin/env bash
printf 'CONFIG:%s\n' "$*"
SH
chmod +x "$MESH_HOME_FAKE/runners/config.sh"

cat > "$MODULES/10-extra.sh" <<'SH'
cmd_hidden() { :; }
cmd_internal() { :; }
cmd_zeta_public() { :; }

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

echo "default public list"
public_out="$(run_mesh __commands 2>&1)"
rc=$?
assert_eq "$rc" 0 "default __commands exits 0"
assert_contains "$public_out" $'config\tEdit personal config from mesh-identity\tcore\tcore\tpublic\tnone' \
    "config is public core command with fanout none"
assert_contains "$public_out" $'zeta-public\tZeta public command\tzeta\tcore\tpublic\tallowed' \
    "default includes public module command"
assert_not_contains "$public_out" "hidden-cmd" "default omits hidden command"
assert_not_contains "$public_out" "internal-cmd" "default omits internal command"
assert_not_contains "$public_out" "__commands" "default omits internal producer command"

echo
echo "--all"
all_out="$(run_mesh __commands --all 2>&1)"
rc=$?
assert_eq "$rc" 0 "__commands --all exits 0"
assert_contains "$all_out" $'hidden-cmd\tHidden command\tzeta\tcore\thidden\tnone' \
    "--all includes hidden command"
assert_not_contains "$all_out" "internal-cmd" "--all omits internal command"
assert_not_contains "$all_out" "__commands" "--all omits internal producer command"

echo
echo "--internal"
internal_out="$(run_mesh __commands --internal 2>&1)"
rc=$?
assert_eq "$rc" 0 "__commands --internal exits 0"
assert_contains "$internal_out" $'internal-cmd\tInternal command\talpha\tcore\tinternal\tnone' \
    "--internal includes internal module command"
assert_contains "$internal_out" $'__commands\tEmit command metadata TSV\tcore\tcore\tinternal\tnone' \
    "--internal includes producer command"

bad_columns="$(printf '%s\n' "$internal_out" | awk -F '\t' 'NF != 6 { print }')"
assert_eq "$bad_columns" "" "all TSV rows have six columns"

bad_fanout="$(printf '%s\n' "$internal_out" | awk -F '\t' '$6 != "allowed" && $6 != "none" { print }')"
assert_eq "$bad_fanout" "" "fanout column is allowed or none"

sorted_internal="$(printf '%s\n' "$internal_out" | LC_ALL=C sort -t $'\t' -k3,3 -k1,1)"
assert_eq "$internal_out" "$sorted_internal" "output is sorted by group then name"

echo
echo "argument validation"
bad_out="$(run_mesh __commands --bogus 2>&1)"
rc=$?
assert_ne "$rc" 0 "unknown __commands flag exits non-zero"
assert_contains "$bad_out" "__commands: unknown arg '--bogus'" "unknown flag prints clear error"

echo
summary
