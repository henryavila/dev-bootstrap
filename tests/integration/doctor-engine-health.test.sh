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

select_bundle() {
    printf '%s\n' "$1" > "$CFG/mesh/selections.list"
}

seed_marker() {
    local name="$1" spec="$2"
    cat > "$STATE/demo__${name}.env" <<EOF
MESH_ITEM_TOPIC="demo"
MESH_ITEM_NAME="$name"
MESH_ITEM_TYPE="custom"
MESH_ITEM_SPEC="$spec"
MESH_ITEM_INSTALLED_AT="fixture"
EOF
}

seed_marker repairable ./repairable.sh
seed_marker platform-disabled ./platform-disabled.sh
seed_marker when-disabled ./when-disabled.sh
seed_marker env-sensitive ./env-sensitive.sh

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
  - name: unowned
    items:
      - name: markerless-broken
        type: custom
        script: ./markerless-broken.sh
      - name: markerless-absent
        type: custom
        script: ./markerless-absent.sh
  - name: wsl-only
    platforms: [wsl]
    items:
      - name: platform-disabled
        type: custom
        script: ./platform-disabled.sh
  - name: when-off
    options:
      - name: enabled
        type: toggle
        label: "Enabled"
        env: DEMO_HEALTH_ENABLED
        default: false
    items:
      - name: when-disabled
        type: custom
        script: ./when-disabled.sh
        when: option.enabled
  - name: env-health
    options:
      - name: token
        type: text
        label: "Token"
        env: DEMO_HEALTH_TOKEN
    items:
      - name: env-sensitive
        type: custom
        script: ./env-sensitive.sh
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

cat > "$TOPICS/demo/markerless-broken.sh" <<SH
SENT_DIR="$SENT"
check() { return 0; }
verify() {
    if [[ -f "\$SENT_DIR/markerless-broken-repaired" ]]; then
        : > "\$SENT_DIR/markerless-broken-verified"
        return 0
    fi
    : > "\$SENT_DIR/markerless-broken-verified-before-repair"
    return 1
}
repair() { : > "\$SENT_DIR/markerless-broken-repaired"; }
SH

cat > "$TOPICS/demo/markerless-absent.sh" <<SH
SENT_DIR="$SENT"
check() { : > "\$SENT_DIR/markerless-absent-checked"; return 1; }
verify() { : > "\$SENT_DIR/markerless-absent-verified"; return 1; }
repair() { : > "\$SENT_DIR/markerless-absent-repaired"; }
SH

cat > "$TOPICS/demo/platform-disabled.sh" <<SH
SENT_DIR="$SENT"
check() { return 0; }
verify() { : > "\$SENT_DIR/platform-disabled-probed"; return 1; }
install() { : > "\$SENT_DIR/platform-disabled-install"; }
repair() { : > "\$SENT_DIR/platform-disabled-repair"; }
SH

cat > "$TOPICS/demo/when-disabled.sh" <<SH
SENT_DIR="$SENT"
check() { return 0; }
verify() { : > "\$SENT_DIR/when-disabled-probed"; return 1; }
install() { : > "\$SENT_DIR/when-disabled-install"; }
repair() { : > "\$SENT_DIR/when-disabled-repair"; }
SH

cat > "$TOPICS/demo/env-sensitive.sh" <<SH
SENT_DIR="$SENT"
check() { return 0; }
verify() {
    if [[ "\${DEMO_HEALTH_TOKEN:-}" == "ok" ]]; then
        : > "\$SENT_DIR/env-sensitive-healthy"
        return 0
    fi
    : > "\$SENT_DIR/env-sensitive-broken"
    return 1
}
install() { : > "\$SENT_DIR/env-sensitive-install"; }
repair() { : > "\$SENT_DIR/env-sensitive-repair"; }
SH

doctor_env() {
    PATH="$FAKEBIN:/usr/bin:/bin" \
    MESH_IDENTITY_DIR="$IDENTITY" \
    XDG_CONFIG_HOME="$CFG" \
    MESH_INSTALL_STATE_DIR="$STATE" \
    MESH_DOCTOR_TOPICS_DIR="$TOPICS" \
    MESH_OS=mac \
    DOCTOR_MARKER_FILES="$NO_MARKER" \
    DOCTOR_LAUNCHD_DIR="$EMPTY_LAUNCHD" \
    NO_COLOR=1 \
        bash "$DOCTOR" "$@"
}

echo "read-only doctor reports broken engine health without mutation"
select_bundle demo/health
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
select_bundle demo/health
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

echo
echo "doctor --fix repairs a selected markerless installed owner but leaves an absent owner alone"
select_bundle demo/unowned
rm -f "$SENT"/* 2>/dev/null || true
set +e
# shellcheck disable=SC2034 # captured so a noisy --quiet regression is inspectable
markerless_out="$(doctor_env --fix --quiet 2>&1)"
markerless_rc=$?
set -u
assert_eq "$markerless_rc" "0" "doctor --fix repairs a selected markerless installed owner"
assert_file_exists "$SENT/markerless-broken-repaired" "doctor --fix repairs a selected markerless item whose presence check passes but verify fails"
assert_file_exists "$SENT/markerless-broken-verified" "doctor --fix re-verifies the repaired markerless item"
assert_file_exists "$STATE/demo__markerless-broken.env" "doctor --fix records ownership only after the markerless repair verifies"
assert_false "[ -f '$SENT/markerless-absent-repaired' ]"
assert_false "[ -f '$STATE/demo__markerless-absent.env' ]"

echo
echo "doctor health follows bundle platforms before probing"
select_bundle demo/wsl-only
rm -f "$SENT"/* 2>/dev/null || true
set +e
platform_out="$(doctor_env --quiet 2>&1)"
platform_rc=$?
set -u
assert_eq "$platform_rc" "0" "doctor ignores a selected bundle excluded by platforms"
assert_not_contains "$platform_out" "demo/platform-disabled" "platform-excluded item is not reported broken"
assert_false "[ -f '$SENT/platform-disabled-probed' ]"

echo
echo "doctor health follows item when gates before probing"
select_bundle demo/when-off
rm -f "$SENT"/* 2>/dev/null || true
set +e
when_out="$(doctor_env --quiet 2>&1)"
when_rc=$?
set -u
assert_eq "$when_rc" "0" "doctor ignores a marker-present item disabled by when"
assert_not_contains "$when_out" "demo/when-disabled" "when-disabled item is not reported broken"
assert_false "[ -f '$SENT/when-disabled-probed' ]"

echo
echo "doctor health probes with the same params/env as the engine"
select_bundle demo/env-health
printf 'DEMO_HEALTH_TOKEN=ok\n' > "$CFG/mesh/params.env"
rm -f "$SENT"/* 2>/dev/null || true
set +e
env_out="$(doctor_env --quiet 2>&1)"
env_rc=$?
set -u
assert_eq "$env_rc" "0" "doctor accepts an item whose verify depends on params.env"
assert_file_exists "$SENT/env-sensitive-healthy" "doctor sourced params.env for the env-sensitive verify"
assert_not_contains "$env_out" "demo/env-sensitive" "env-sensitive item is not falsely reported broken"

summary
