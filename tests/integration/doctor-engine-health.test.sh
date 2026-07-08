#!/usr/bin/env bash
# tests/integration/doctor-engine-health.test.sh
#
# Red regression suite for `mesh doctor` engine health. Read-only doctor should
# report selected installed-but-broken items without mutation; `--fix` should run
# the owner repair lifecycle, re-run read-only verification, and leave the item
# healthy.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
DOCTOR="$WS/scripts/runners/doctor.sh"
# shellcheck source=../lib/assert.sh
# shellcheck disable=SC1091
source "$WS/tests/lib/assert.sh"

ROOT="$(mktemp -d -t doctor-engine-health.XXXXXX)"
cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT

TOPICS="$ROOT/topics"
STATE="$ROOT/state"
SENT="$ROOT/sentinels"
CFG="$ROOT/config"
IDENTITY="$ROOT/identity"
EMPTY_LAUNCHD="$ROOT/empty-launchd"
NO_MARKER="$ROOT/no-marker"
FAKEBIN="$ROOT/bin"
mkdir -p "$TOPICS/demo" "$STATE" "$SENT" "$CFG/mesh" "$IDENTITY" "$EMPTY_LAUNCHD" "$FAKEBIN"

cat > "$CFG/mesh/selections.list" <<'EOF'
demo/health
EOF

cat > "$STATE/demo__repairable.env" <<'EOF'
MESH_ITEM_TOPIC="demo"
MESH_ITEM_NAME="repairable"
MESH_ITEM_TYPE="custom"
MESH_ITEM_SPEC="./repairable.sh"
MESH_ITEM_INSTALLED_AT="fixture"
EOF

cat > "$TOPICS/demo/manifest.yaml" <<'YAML'
topic:
  label: "Demo"
  order: 10
bundles:
  - name: health
    items:
      - name: repairable
        type: custom
        script: ./repairable.sh
YAML

cat > "$TOPICS/demo/repairable.sh" <<SH
SENT_DIR="$SENT"
check() { return 0; }
verify() {
    if [[ -f "\$SENT_DIR/repair-ran" ]]; then
        : > "\$SENT_DIR/verify-after-repair"
        return 0
    fi
    : > "\$SENT_DIR/verify-readonly"
    printf 'demo/repairable: verify failed\n' >&2
    return 1
}
install() { : > "\$SENT_DIR/install-ran"; }
repair() { : > "\$SENT_DIR/repair-ran"; }
SH

doctor_env() {
    PATH="$FAKEBIN:/usr/bin:/bin" \
    MESH_IDENTITY_DIR="$IDENTITY" \
    XDG_CONFIG_HOME="$CFG" \
    MESH_INSTALL_STATE_DIR="$STATE" \
    MESH_DOCTOR_TOPICS_DIR="$TOPICS" \
    DOCTOR_MARKER_FILES="$NO_MARKER" \
    DOCTOR_LAUNCHD_DIR="$EMPTY_LAUNCHD" \
    NO_COLOR=1 \
        bash "$DOCTOR" "$@"
}

echo "read-only doctor reports broken engine health without mutation"
rm -f "$SENT"/* 2>/dev/null || true
set +e
readonly_out="$(doctor_env --quiet 2>&1)"
readonly_rc=$?
set -u
assert_eq "$readonly_rc" "1" "read-only doctor exits non-zero for selected installed-but-broken item"
assert_contains "$readonly_out" "demo/repairable" "read-only doctor output names the broken engine item"
assert_file_exists "$SENT/verify-readonly" "read-only doctor runs the item verify probe"
assert_false "[ -f '$SENT/repair-ran' ]"
assert_false "[ -f '$SENT/install-ran' ]"

echo
echo "doctor --fix repairs through the owner lifecycle and revalidates"
rm -f "$SENT"/* 2>/dev/null || true
set +e
fix_out="$(doctor_env --fix --quiet 2>&1)"
fix_rc=$?
set -u
assert_eq "$fix_rc" "0" "doctor --fix exits 0 after repairing and revalidating"
assert_file_exists "$SENT/repair-ran" "doctor --fix calls the custom repair() hook"
assert_file_exists "$SENT/verify-after-repair" "doctor --fix re-runs verify after repair"
assert_false "[ -f '$SENT/install-ran' ]"
assert_contains "$fix_out" "demo/repairable" "doctor --fix output names the repaired engine item"

summary
