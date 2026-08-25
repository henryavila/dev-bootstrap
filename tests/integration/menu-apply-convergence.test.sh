#!/usr/bin/env bash
# tests/integration/menu-apply-convergence.test.sh
#
# Regression coverage for setup/menu routing after install-engine convergence:
# `mesh menu --apply` must call the normal install lifecycle, which now verifies
# check-present items before skip and repairs broken selected items without a
# force reinstall. The fixture uses the real menu runner and real install-engine
# against a temp topics tree; only Node and uninstall-engine are stubbed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
# shellcheck disable=SC1091
source "$ROOT/tests/lib/assert.sh"

SANDBOX="$(mktemp -d -t menu-apply-convergence.XXXXXX)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

FIX="$SANDBOX/ws"
BIN="$SANDBOX/bin"
CFG="$SANDBOX/config"
STATE="$SANDBOX/state"
SENT="$SANDBOX/sentinels"
ORDER="$SANDBOX/order.log"
mkdir -p "$FIX/scripts/runners" "$FIX/scripts/menu" "$FIX/topics/demo" "$BIN" "$CFG/mesh" "$STATE" "$SENT"

cp "$ROOT/scripts/runners/menu.sh" "$FIX/scripts/runners/menu.sh"
mkdir -p "$FIX/scripts"
cp -R "$ROOT/scripts/lib" "$FIX/scripts/lib"
touch "$FIX/scripts/menu/index.js"

cat > "$FIX/scripts/lib/uninstall-engine.sh" <<'SH'
#!/usr/bin/env bash
printf 'uninstall\n' >> "${ORDER:?}"
exit "${UNINSTALL_RC:-0}"
SH
chmod +x "$FIX/scripts/lib/uninstall-engine.sh"

cat > "$BIN/node" <<'SH'
#!/usr/bin/env bash
mkdir -p "${XDG_CONFIG_HOME:?}/mesh"
printf '# mesh selections\n' > "$XDG_CONFIG_HOME/mesh/selections.list"
IFS=',' read -r -a selected_entries <<< "${MENU_FIXTURE_SELECTIONS:-demo/broken}"
for entry in "${selected_entries[@]}"; do
    [[ -z "$entry" ]] || printf '%s\n' "$entry" >> "$XDG_CONFIG_HOME/mesh/selections.list"
done
if [[ -n "${MENU_FIXTURE_REMOVALS:-}" ]]; then
    printf '# mesh removals\n' > "$XDG_CONFIG_HOME/mesh/removals.list"
    IFS=',' read -r -a removal_entries <<< "$MENU_FIXTURE_REMOVALS"
    for entry in "${removal_entries[@]}"; do
        [[ -z "$entry" ]] || printf '%s\n' "$entry" >> "$XDG_CONFIG_HOME/mesh/removals.list"
    done
fi
SH
chmod +x "$BIN/node"

cat > "$FIX/topics/demo/manifest.yaml" <<'YAML'
topic:
  label: "Demo"
  order: 10
bundles:
  - name: broken
    items:
      - name: broken-tool
        type: custom
        script: ./broken-tool.sh
  - name: healthy
    items:
      - name: healthy-tool
        type: custom
        script: ./healthy-tool.sh
  - name: old
    items:
      - name: old-tool
        type: custom
        script: ./old-tool.sh
YAML

cat > "$FIX/topics/demo/broken-tool.sh" <<SH
SENT_DIR="$SENT"
ORDER_FILE="$ORDER"
check() { return 0; }
verify() {
    if [[ -f "\$SENT_DIR/broken-repaired" ]]; then
        : > "\$SENT_DIR/broken-verified-after-repair"
        return 0
    fi
    : > "\$SENT_DIR/broken-verify-failed"
    return 1
}
install() { : > "\$SENT_DIR/broken-install-ran"; }
repair() {
    printf 'install-repair\n' >> "\$ORDER_FILE"
    : > "\$SENT_DIR/broken-repaired"
}
SH

cat > "$FIX/topics/demo/healthy-tool.sh" <<SH
SENT_DIR="$SENT"
check() { return 0; }
verify() { : > "\$SENT_DIR/healthy-verified"; return 0; }
install() { : > "\$SENT_DIR/healthy-install-ran"; }
SH

cat > "$FIX/topics/demo/old-tool.sh" <<SH
check() { return 0; }
verify() { return 0; }
install() { :; }
SH

run_menu_apply() {
    PATH="$BIN:$PATH" \
    XDG_CONFIG_HOME="$CFG" \
    MESH_INSTALL_STATE_DIR="$STATE" \
    ORDER="$ORDER" \
        bash "$FIX/scripts/runners/menu.sh" --apply >"$SANDBOX/menu.out" 2>"$SANDBOX/menu.err"
}

reset_fixture() {
    rm -f "$SENT"/* "$STATE"/*.env "$ORDER" "$CFG/mesh/removals.list" "$SANDBOX/menu.out" "$SANDBOX/menu.err" 2>/dev/null || true
}

echo "menu --apply repairs a selected check-present but verify-broken item"
reset_fixture
MENU_FIXTURE_SELECTIONS=demo/broken run_menu_apply
rc=$?
assert_eq "$rc" "0" "menu --apply exits 0 after engine repair"
assert_file_exists "$SENT/broken-verify-failed" "menu apply path runs verify before skip"
assert_file_exists "$SENT/broken-repaired" "menu apply path repairs through owner repair()"
assert_file_exists "$SENT/broken-verified-after-repair" "menu apply path re-verifies after repair"
assert_false "[ -f '$SENT/broken-install-ran' ]"

echo
echo "menu --apply leaves healthy selected items installed without force reinstall"
reset_fixture
MENU_FIXTURE_SELECTIONS=demo/healthy run_menu_apply
rc=$?
assert_eq "$rc" "0" "menu --apply exits 0 for healthy selected item"
assert_file_exists "$SENT/healthy-verified" "healthy selected item is verified"
assert_false "[ -f '$SENT/healthy-install-ran' ]"

echo
echo "menu --apply keeps removals ordered before the convergent install pass"
reset_fixture
MENU_FIXTURE_SELECTIONS=demo/broken MENU_FIXTURE_REMOVALS=demo/old run_menu_apply
rc=$?
assert_eq "$rc" "0" "menu --apply exits 0 when uninstall pass succeeds before repair"
assert_eq "$(sed -n '1p' "$ORDER")" "uninstall" "uninstall pass runs before install-engine"
assert_eq "$(sed -n '2p' "$ORDER")" "install-repair" "install-engine repair runs after uninstall"

echo
echo "setup.sh still routes normal setup through install-engine, reserving --repair for repair mode"
setup_src="$(awk '/^engine_args=\(/,/install-engine\.sh/' "$ROOT/setup.sh")"
assert_contains "$setup_src" 'engine_args=(--selections "$SELECTIONS_FILE" --platform "$OS")' \
    "setup normal path builds install-engine args without --repair"
assert_contains "$setup_src" '[[ "$REPAIR_MODE" == "1" ]] && engine_args+=(--repair)' \
    "setup --repair remains the explicit repair mode"

summary
