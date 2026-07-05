#!/usr/bin/env bash
# tests/integration/menu-apply-uninstall.test.sh
#
# Regression coverage for `mesh menu --apply`: the TUI writes removals.list for
# deselected bundles, and the runner must call uninstall-engine before install.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
# shellcheck disable=SC1091
source "$ROOT/tests/lib/assert.sh"

SANDBOX="$(mktemp -d -t menu-apply-uninstall.XXXXXX)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

FIX="$SANDBOX/ws"
BIN="$SANDBOX/bin"
CFG="$SANDBOX/config"
ORDER="$SANDBOX/order.log"
mkdir -p "$FIX/scripts/runners" "$FIX/scripts/lib" "$FIX/scripts/menu" "$BIN" "$CFG/mesh"

cp "$ROOT/scripts/runners/menu.sh" "$FIX/scripts/runners/menu.sh"
touch "$FIX/scripts/menu/index.js"

cat > "$FIX/scripts/lib/log.sh" <<'SH'
log_info()  { printf '[INFO] %s\n' "$*" >&2; }
log_warn()  { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
info()      { log_info "$@"; }
SH
cat > "$FIX/scripts/lib/detect-os.sh" <<'SH'
#!/usr/bin/env bash
printf 'mac\n'
SH
cat > "$FIX/scripts/lib/uninstall-engine.sh" <<'SH'
#!/usr/bin/env bash
printf 'uninstall:%s\n' "$*" >> "${ORDER:?}"
exit "${UNINSTALL_RC:-0}"
SH
cat > "$FIX/scripts/lib/install-engine.sh" <<'SH'
#!/usr/bin/env bash
args=("$@")
for arg in "${args[@]}"; do
    if [[ "$arg" == "--print-closure" ]]; then
        selections=""
        i=0
        while (( i < ${#args[@]} )); do
            if [[ "${args[$i]}" == "--selections" ]]; then
                selections="${args[$((i + 1))]:-}"
                break
            fi
            i=$((i + 1))
        done
        grep -vE '^[[:space:]]*(#|$)' "$selections" 2>/dev/null || true
        if [[ -n "${MENU_FIXTURE_EXTRA_CLOSURE:-}" ]]; then
            IFS=',' read -r -a extra_entries <<< "$MENU_FIXTURE_EXTRA_CLOSURE"
            for entry in "${extra_entries[@]}"; do
                [[ -z "$entry" ]] || printf '%s\n' "$entry"
            done
        fi
        exit 0
    fi
done
printf 'install:%s\n' "$*" >> "${ORDER:?}"
SH
chmod +x "$FIX/scripts/lib/"*.sh

cat > "$BIN/node" <<'SH'
#!/usr/bin/env bash
mkdir -p "${XDG_CONFIG_HOME:?}/mesh"
printf '# mesh selections\n' > "$XDG_CONFIG_HOME/mesh/selections.list"
IFS=',' read -r -a selected_entries <<< "${MENU_FIXTURE_SELECTIONS:-remote-access/tailscale}"
for entry in "${selected_entries[@]}"; do
    [[ -z "$entry" ]] || printf '%s\n' "$entry" >> "$XDG_CONFIG_HOME/mesh/selections.list"
done
printf '# mesh removals\n' > "$XDG_CONFIG_HOME/mesh/removals.list"
case "${MENU_FIXTURE_REMOVALS:-remote-access/code-server}" in
    empty) ;;
    *)
        IFS=',' read -r -a removal_entries <<< "${MENU_FIXTURE_REMOVALS:-remote-access/code-server}"
        for entry in "${removal_entries[@]}"; do
            [[ -z "$entry" ]] || printf '%s\n' "$entry" >> "$XDG_CONFIG_HOME/mesh/removals.list"
        done
        ;;
esac
SH
chmod +x "$BIN/node"

echo "menu --apply runs uninstall before install when removals.list has entries"
PATH="$BIN:$PATH" XDG_CONFIG_HOME="$CFG" ORDER="$ORDER" \
    bash "$FIX/scripts/runners/menu.sh" --apply >/dev/null 2>&1
assert_eq "$(sed -n '1s/:.*//p' "$ORDER")" "uninstall" "uninstall pass runs first"
assert_eq "$(sed -n '2s/:.*//p' "$ORDER")" "install" "install pass still runs after uninstall"
assert_contains "$(cat "$ORDER")" "uninstall:--selections" "uninstall receives a filtered removals file"
assert_contains "$(cat "$ORDER")" "--selections $CFG/mesh/selections.list" "install receives selections.list"
assert_false "[ -e '$CFG/mesh/removals.list' ]"

echo
echo "menu --apply does not uninstall removals still required by final closure"
rm -f "$ORDER"
PATH="$BIN:$PATH" XDG_CONFIG_HOME="$CFG" ORDER="$ORDER" \
    MENU_FIXTURE_EXTRA_CLOSURE="remote-access/code-server" \
    bash "$FIX/scripts/runners/menu.sh" --apply >/dev/null 2>&1
assert_eq "$(wc -l < "$ORDER" | tr -d ' ')" "1" "only install runs when removal is still selected by closure"
assert_eq "$(sed -n '1s/:.*//p' "$ORDER")" "install" "closure-kept removals do not call uninstall"
assert_false "[ -e '$CFG/mesh/removals.list' ]"

echo
echo "menu --apply returns uninstall failure after install pass and keeps removals"
rm -f "$ORDER"
set +e
failure_out="$(
    PATH="$BIN:$PATH" \
    XDG_CONFIG_HOME="$CFG" \
    ORDER="$ORDER" \
    UNINSTALL_RC=42 \
    bash "$FIX/scripts/runners/menu.sh" --apply 2>&1 >/dev/null
)"
failure_rc=$?
set -e
assert_eq "$failure_rc" "42" "menu exits with uninstall failure after apply"
assert_eq "$(sed -n '1s/:.*//p' "$ORDER")" "uninstall" "failed uninstall still runs before install"
assert_eq "$(sed -n '2s/:.*//p' "$ORDER")" "install" "install pass still runs after failed uninstall"
assert_true "[ -e '$CFG/mesh/removals.list' ]"
assert_contains "$failure_out" "pending removals kept at $CFG/mesh/removals.list" \
    "menu tells the user where pending removals remain"

echo
echo "header-only removals.list skips uninstall"
rm -f "$ORDER"
PATH="$BIN:$PATH" XDG_CONFIG_HOME="$CFG" ORDER="$ORDER" MENU_FIXTURE_REMOVALS=empty \
    bash "$FIX/scripts/runners/menu.sh" --apply >/dev/null 2>&1
assert_eq "$(wc -l < "$ORDER" | tr -d ' ')" "1" "only install runs when removals.list has no real entries"
assert_eq "$(sed -n '1s/:.*//p' "$ORDER")" "install" "header-only removals does not call uninstall"

summary
