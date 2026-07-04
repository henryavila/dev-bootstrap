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
SH
cat > "$FIX/scripts/lib/install-engine.sh" <<'SH'
#!/usr/bin/env bash
printf 'install:%s\n' "$*" >> "${ORDER:?}"
SH
chmod +x "$FIX/scripts/lib/"*.sh

cat > "$BIN/node" <<'SH'
#!/usr/bin/env bash
mkdir -p "${XDG_CONFIG_HOME:?}/mesh"
printf '# mesh selections\nremote-access/tailscale\n' > "$XDG_CONFIG_HOME/mesh/selections.list"
case "${MENU_FIXTURE_REMOVALS:-real}" in
    real)  printf '# mesh removals\nremote-access/code-server\n' > "$XDG_CONFIG_HOME/mesh/removals.list" ;;
    empty) printf '# mesh removals\n' > "$XDG_CONFIG_HOME/mesh/removals.list" ;;
esac
SH
chmod +x "$BIN/node"

echo "menu --apply runs uninstall before install when removals.list has entries"
PATH="$BIN:$PATH" XDG_CONFIG_HOME="$CFG" ORDER="$ORDER" \
    bash "$FIX/scripts/runners/menu.sh" --apply >/dev/null 2>&1
assert_eq "$(sed -n '1s/:.*//p' "$ORDER")" "uninstall" "uninstall pass runs first"
assert_eq "$(sed -n '2s/:.*//p' "$ORDER")" "install" "install pass still runs after uninstall"
assert_contains "$(cat "$ORDER")" "--selections $CFG/mesh/removals.list" "uninstall receives removals.list"
assert_contains "$(cat "$ORDER")" "--selections $CFG/mesh/selections.list" "install receives selections.list"
assert_false "[ -e '$CFG/mesh/removals.list' ]"

echo
echo "header-only removals.list skips uninstall"
rm -f "$ORDER"
PATH="$BIN:$PATH" XDG_CONFIG_HOME="$CFG" ORDER="$ORDER" MENU_FIXTURE_REMOVALS=empty \
    bash "$FIX/scripts/runners/menu.sh" --apply >/dev/null 2>&1
assert_eq "$(wc -l < "$ORDER" | tr -d ' ')" "1" "only install runs when removals.list has no real entries"
assert_eq "$(sed -n '1s/:.*//p' "$ORDER")" "install" "header-only removals does not call uninstall"

summary
