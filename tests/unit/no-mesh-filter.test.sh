#!/usr/bin/env bash
# T-002 — --no-mesh parse + data-driven membership filter.
# Catalog checks use setup.sh --no-mesh --list-bundles (exits before sudo/menu).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

SETUP="$WS/setup.sh"
HELPER="$WS/scripts/lib/no-mesh.sh"
CMD_SETUP="$WS/scripts/commands/setup.sh"
CMD_MENU="$WS/scripts/commands/menu.sh"
MESH="$WS/bin/mesh"

assert_file_exists "$SETUP" "setup.sh exists"
assert_file_exists "$HELPER" "scripts/lib/no-mesh.sh exists"
assert_file_exists "$CMD_SETUP" "scripts/commands/setup.sh exists"
assert_file_exists "$CMD_MENU" "scripts/commands/menu.sh exists"

# --- helper: data-driven omit, not a hardcoded name list ---
assert_pattern_absent "$HELPER" 'personal/personal' \
    "no-mesh.sh does not hardcode personal/personal"
assert_pattern_absent "$HELPER" 'identity/identity' \
    "no-mesh.sh does not hardcode identity/identity"
assert_pattern_absent "$HELPER" 'syncthing/syncthing' \
    "no-mesh.sh does not hardcode syncthing/syncthing"
assert_pattern_absent "$HELPER" 'code-server' \
    "no-mesh.sh does not hardcode code-server"

if [[ -f "$HELPER" ]]; then
    # shellcheck source=/dev/null
    . "$HELPER"

    MESH_NO_MESH=1
    if no_mesh_omit_bundle mesh; then
        pass "MESH_NO_MESH=1 omits membership=mesh"
    else
        fail "MESH_NO_MESH=1 omits membership=mesh"
    fi
    if no_mesh_omit_bundle ""; then
        fail "MESH_NO_MESH=1 keeps untagged membership (got omit)"
    else
        pass "MESH_NO_MESH=1 keeps untagged membership"
    fi
    if no_mesh_omit_bundle other; then
        fail "MESH_NO_MESH=1 keeps unknown membership (got omit)"
    else
        pass "MESH_NO_MESH=1 keeps unknown membership"
    fi

    MESH_NO_MESH=0
    if no_mesh_omit_bundle mesh; then
        fail "MESH_NO_MESH=0 keeps membership=mesh (got omit)"
    else
        pass "MESH_NO_MESH=0 keeps membership=mesh"
    fi
    unset MESH_NO_MESH
    if no_mesh_omit_bundle mesh; then
        fail "unset MESH_NO_MESH keeps membership=mesh (got omit)"
    else
        pass "unset MESH_NO_MESH keeps membership=mesh"
    fi

    # Empty topics vanish: a topic whose only bundle is membership=mesh emits nothing.
    MESH_NO_MESH=1
    filtered="$(
        printf '%s\n' \
            $'syncthing\tsyncthing\tmesh' \
            $'remote-access\tssh\t' \
            $'remote-access\ttailscale\tmesh' \
            $'foundation\tbase\t' |
            no_mesh_filter_records
    )"
    assert_not_contains "$filtered" "syncthing" "filter omits empty syncthing topic"
    assert_contains "$filtered" $'remote-access\tssh' "filter keeps untagged ssh"
    assert_not_contains "$filtered" "tailscale" "filter drops membership tailscale"
    assert_contains "$filtered" $'foundation\tbase' "filter keeps foundation/base"
fi

# --- setup.sh: --no-mesh in the same arg loop as --list-bundles, export before menu ---
# grep treats a pattern starting with -- as options; match the case-arm suffix.
assert_file_contains "$SETUP" 'list-bundles)' \
    "setup.sh parses --list-bundles"
assert_file_contains "$SETUP" 'no-mesh)' \
    "setup.sh parses --no-mesh in the arg loop"
assert_file_contains "$SETUP" 'export MESH_NO_MESH' \
    "setup.sh exports MESH_NO_MESH when the flag is seen"

# Same arg-loop: both flags appear before the loop's `done` that precedes usage().
order_probe="$(python3 - "$SETUP" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
export_at = text.find("export MESH_NO_MESH")
menu_at = text.find("should_run_menu")
list_at = text.find("--list-bundles)")
flag_at = text.find("--no-mesh)")
if flag_at < 0 or list_at < 0:
    print("MISSING_FLAGS")
    sys.exit(0)
done_after_list = text.find("\ndone\n", list_at)
if flag_at > done_after_list:
    print("FLAG_AFTER_ARG_LOOP")
    sys.exit(0)
if export_at < 0 or menu_at < 0 or export_at > menu_at:
    print("EXPORT_NOT_BEFORE_MENU")
    sys.exit(0)
print("OK")
PY
)"
assert_eq "$order_probe" "OK" "export MESH_NO_MESH happens in the arg loop, before should_run_menu"

# --- catalog: never launch the interactive menu; --list-bundles exits first ---
unflagged=""
unflagged_rc=0
unflagged=$(bash "$SETUP" --list-bundles 2>&1) || unflagged_rc=$?
assert_eq "$unflagged_rc" "0" "unflagged --list-bundles exits 0"
assert_contains "$unflagged" "personal/personal" "unflagged catalog lists personal/personal"
assert_contains "$unflagged" "identity/identity" "unflagged catalog lists identity/identity"
assert_contains "$unflagged" "syncthing/syncthing" "unflagged catalog lists syncthing/syncthing"
assert_contains "$unflagged" "remote-access/tailscale" "unflagged catalog lists remote-access/tailscale"
assert_contains "$unflagged" "remote-access/code-server" "unflagged catalog lists remote-access/code-server"
assert_contains "$unflagged" "foundation/base" "unflagged catalog lists foundation/base"
assert_contains "$unflagged" "remote-access/ssh" "unflagged catalog lists remote-access/ssh"

flagged=""
flagged_rc=0
flagged=$(bash "$SETUP" --no-mesh --list-bundles 2>&1) || flagged_rc=$?
assert_eq "$flagged_rc" "0" "--no-mesh --list-bundles exits 0 (flag accepted)"
assert_not_contains "$flagged" "unknown arg" "--no-mesh is not rejected as unknown"
assert_not_contains "$flagged" "personal/personal" "flagged catalog omits personal/personal"
assert_not_contains "$flagged" "identity/identity" "flagged catalog omits identity/identity"
assert_not_contains "$flagged" "syncthing/syncthing" "flagged catalog omits syncthing/syncthing"
assert_not_contains "$flagged" "remote-access/tailscale" "flagged catalog omits remote-access/tailscale"
assert_not_contains "$flagged" "remote-access/code-server" "flagged catalog omits remote-access/code-server"
assert_not_contains "$flagged" "syncthing/" "flagged catalog omits empty syncthing topic"
assert_contains "$flagged" "foundation/base" "flagged catalog still lists foundation/base"
assert_contains "$flagged" "remote-access/ssh" "flagged catalog still lists untagged ssh"

# --- command wrappers: help documents --no-mesh; menu accepts it without launching TUI ---
assert_file_contains "$CMD_MENU" 'no-mesh)' \
    "scripts/commands/menu.sh accepts --no-mesh"
assert_file_contains "$CMD_MENU" 'MESH_NO_MESH' \
    "scripts/commands/menu.sh exports MESH_NO_MESH"
assert_file_contains "$CMD_SETUP" 'no-mesh' \
    "scripts/commands/setup.sh help documents --no-mesh"

menu_help=""
menu_help_rc=0
menu_help=$(bash "$MESH" menu --no-mesh -h 2>&1) || menu_help_rc=$?
assert_eq "$menu_help_rc" "0" "mesh menu --no-mesh -h exits 0 (does not launch TUI)"
assert_contains "$menu_help" "Usage: mesh menu" "mesh menu --no-mesh -h prints usage (not unknown-arg)"
assert_contains "$menu_help" "[--no-mesh]" "mesh menu help mentions --no-mesh"

setup_help=""
setup_help_rc=0
setup_help=$(bash "$MESH" setup -h 2>&1) || setup_help_rc=$?
assert_eq "$setup_help_rc" "0" "mesh setup -h exits 0"
assert_contains "$setup_help" "no-mesh" "mesh setup help mentions --no-mesh"

summary
