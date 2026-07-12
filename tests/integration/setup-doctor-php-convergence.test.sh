#!/usr/bin/env bash
# tests/integration/setup-doctor-php-convergence.test.sh
#
# F4 command-semantics contract. Exercises the real command modules, menu
# runner, auto-update motor, and install engine against an isolated workstation
# fixture. No network, package manager, service manager, or host state is used.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
SETUP_MODULE="$WS/scripts/commands/setup.sh"
DOCTOR_MODULE="$WS/scripts/commands/doctor.sh"
UPDATE_MODULE="$WS/scripts/commands/update.sh"
RUNTIME_RESOLVER="$WS/topics/web/wsl/php-runtime.sh"
# shellcheck source=../lib/assert.sh
# shellcheck disable=SC1091
source "$WS/tests/lib/assert.sh"

ROOT="$(mktemp -d -t setup-doctor-php-convergence.XXXXXX)"
cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT

FIX="$ROOT/mesh-workstation"
CFG="$ROOT/config"
STATE="$ROOT/state"
SENT="$ROOT/sentinels"
BIN="$ROOT/bin"
HOME_FIX="$ROOT/home"
UPDATE_STATE="$ROOT/update-state"
SETUP_CALLS="$ROOT/setup-calls"
mkdir -p "$FIX/scripts/runners" "$FIX/scripts/menu" \
    "$FIX/topics/runtime" "$FIX/topics/web" "$FIX/topics/demo" \
    "$CFG/mesh" "$STATE" "$SENT" "$BIN" "$HOME_FIX" "$UPDATE_STATE"

cp -R "$WS/scripts/lib" "$FIX/scripts/lib"
cp "$WS/scripts/runners/menu.sh" "$FIX/scripts/runners/menu.sh"
cp "$WS/scripts/runners/auto-update.sh" "$FIX/scripts/runners/auto-update.sh"
touch "$FIX/scripts/menu/index.js" "$SETUP_CALLS"

# The fixture setup is deliberately thin: command routing remains production
# code, while host provisioning is replaced by the real engine over temp topics.
cat > "$FIX/setup.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repair=0
for arg in "$@"; do
    case "$arg" in
        --non-interactive) : ;;
        --repair) repair=1 ;;
        *) printf 'fixture setup: unexpected arg: %s\n' "$arg" >&2; exit 64 ;;
    esac
done
printf '%s\n' "$*" >> "${SETUP_CALLS:?}"
args=(
    --topics-dir "$ROOT/topics"
    --selections "${XDG_CONFIG_HOME:?}/mesh/selections.list"
    --params "$XDG_CONFIG_HOME/mesh/params.env"
    --platform wsl
    --non-interactive
)
(( repair == 1 )) && args+=(--repair)
exec bash "$ROOT/scripts/lib/install-engine.sh" "${args[@]}"
SH
chmod +x "$FIX/setup.sh"

cat > "$BIN/node" <<'SH'
#!/usr/bin/env bash
mkdir -p "${XDG_CONFIG_HOME:?}/mesh"
printf '%s\n' 'web/stack' > "$XDG_CONFIG_HOME/mesh/selections.list"
printf '%s\n' 'PHP_VERSIONS="8.4"' 'PHP_DEFAULT="8.4"' \
    > "$XDG_CONFIG_HOME/mesh/params.env"
SH
cat > "$BIN/sudo" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "-v" ]] && exit 0
exec "$@"
SH
cat > "$BIN/mesh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$BIN/php8.4" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-r" ]]; then
    printf '8.4'
else
    printf 'PHP 8.4 fixture\n'
fi
SH
chmod +x "$BIN/node" "$BIN/sudo" "$BIN/mesh" "$BIN/php8.4"
ln -s php8.4 "$BIN/php"

cat > "$FIX/topics/runtime/manifest.yaml" <<'YAML'
topic:
  label: Runtime
  order: 20
bundles:
  - name: php
    options:
      - name: versions
        type: multiselect
        label: PHP versions
        env: PHP_VERSIONS
        default: ["8.4"]
      - name: default-version
        type: select
        label: Default PHP
        env: PHP_DEFAULT
        default: "8.4"
    items:
      - name: runtime-owner
        type: custom
        script: ./runtime-owner.sh
YAML

cat > "$FIX/topics/runtime/runtime-owner.sh" <<'SH'
check() { [[ -f "${SENT_DIR:?}/runtime-ready" ]]; }
install() {
    printf '%s|%s\n' "${PHP_VERSIONS:-}" "${PHP_DEFAULT:-}" > "$SENT_DIR/runtime-consumer"
    : > "$SENT_DIR/runtime-ready"
}
verify() { check; }
repair() { install; }
SH

cat > "$FIX/topics/web/manifest.yaml" <<'YAML'
topic:
  label: Web
  order: 70
bundles:
  - name: stack
    requires_bundles:
      - runtime/php
    items:
      - name: legacy-config
        type: custom
        script: ./legacy-config.sh
      - name: service-convergence
        type: custom
        script: ./service-convergence.sh
YAML

cat > "$FIX/topics/web/legacy-config.sh" <<'SH'
check() { [[ -f "${SENT_DIR:?}/legacy-ready" ]]; }
install() { : > "$SENT_DIR/legacy-ready"; }
verify() { check; }
repair() { install; }
SH

cat > "$FIX/topics/web/service-convergence.sh" <<'SH'
# shellcheck disable=SC1090
. "${RUNTIME_RESOLVER:?}"
resolve_runtime() {
    local versions default
    versions="$(_mesh_web_php_runtime_versions)" || return 1
    default="$(_mesh_web_php_runtime_default "$versions")" || return 1
    RESOLVED_VERSIONS="$(printf '%s\n' "$versions" | paste -sd ' ' -)"
    RESOLVED_DEFAULT="$default"
}
check() {
    resolve_runtime || return 1
    [[ -f "${SENT_DIR:?}/service-ready" ]]
}
install() {
    resolve_runtime || return 1
    printf '%s|%s\n' "$RESOLVED_VERSIONS" "$RESOLVED_DEFAULT" > "$SENT_DIR/web-consumer"
    : > "$SENT_DIR/service-ready"
}
verify() { check; }
repair() { install; }
SH

cat > "$FIX/topics/demo/manifest.yaml" <<'YAML'
topic:
  label: Demo
  order: 10
bundles:
  - name: lifecycle
    items:
      - name: stable
        type: custom
        script: ./stable.sh
      - name: flaky
        type: custom
        script: ./flaky.sh
YAML

cat > "$FIX/topics/demo/stable.sh" <<'SH'
check() { [[ -f "${SENT_DIR:?}/stable-ready" ]]; }
install() {
    printf 'install\n' >> "$SENT_DIR/stable-installs"
    : > "$SENT_DIR/stable-ready"
}
verify() { check; }
repair() { install; }
SH

cat > "$FIX/topics/demo/flaky.sh" <<'SH'
check() { return 0; }
verify() { [[ -f "${SENT_DIR:?}/flaky-ready" ]]; }
install() { repair; }
repair() {
    printf 'attempt\n' >> "$SENT_DIR/flaky-attempts"
    if [[ -f "$SENT_DIR/flaky-fail-once" ]]; then
        rm -f "$SENT_DIR/flaky-fail-once"
        return 78
    fi
    : > "$SENT_DIR/flaky-ready"
}
SH

fixture_env() {
    HOME="$HOME_FIX" \
    XDG_CONFIG_HOME="$CFG" \
    XDG_STATE_HOME="$ROOT/xdg-state" \
    MESH_INSTALL_STATE_DIR="$STATE" \
    SENT_DIR="$SENT" \
    SETUP_CALLS="$SETUP_CALLS" \
    RUNTIME_RESOLVER="$RUNTIME_RESOLVER" \
    PHP_CLI_BIN_DIR="$BIN" \
    PATH="$BIN:$PATH" \
        "$@"
}

reset_fixture() {
    rm -rf "$STATE" "$SENT" "$CFG/mesh"
    mkdir -p "$STATE" "$SENT" "$CFG/mesh"
    : > "$SETUP_CALLS"
}

select_bundle() {
    printf '%s\n' "$1" > "$CFG/mesh/selections.list"
}

seed_marker() {
    local topic="$1" name="$2" type="$3" spec="$4"
    cat > "$STATE/${topic}__${name}.env" <<EOF
MESH_ITEM_TOPIC="$topic"
MESH_ITEM_NAME="$name"
MESH_ITEM_TYPE="$type"
MESH_ITEM_SPEC="$spec"
MESH_ITEM_INSTALLED_AT="fixture"
EOF
}

run_setup_command() {
    fixture_env env HERE="$FIX/scripts" SETUP_MODULE="$SETUP_MODULE" bash -c '
        mesh_register_command() { :; }
        _die() { printf "%s\n" "$*" >&2; exit 1; }
        source "$SETUP_MODULE"
        cmd_setup_run --no-update --non-interactive
    '
}

run_doctor_fix() {
    fixture_env env FIX="$FIX" DOCTOR_MODULE="$DOCTOR_MODULE" bash -c '
        mesh_register_command() { :; }
        _die() { printf "%s\n" "$*" >&2; exit 1; }
        _resolve_workstation_repo() { printf "%s\n" "$FIX"; }
        _resolve_companion() { return 1; }
        source "$DOCTOR_MODULE"
        cmd_doctor_run --fix
    '
}

echo "setup normal apply resolves a fresh PHP/web closure without params"
reset_fixture
select_bundle web/stack
setup_out="$(run_setup_command 2>&1)"
setup_rc=$?
assert_eq "$setup_rc" "0" "mesh setup normal lifecycle exits 0"
assert_false "[ -e '$CFG/mesh/params.env' ]"
assert_eq "$(cat "$SENT/runtime-consumer" 2>/dev/null)" "8.4|8.4" \
    "languages/php receives its non-interactive defaults"
assert_eq "$(cat "$SENT/web-consumer" 2>/dev/null)" "8.4|8.4" \
    "dependent web owner resolves the same runtime without persisted params"
assert_contains "$setup_out" "auto-selecting runtime/php" \
    "setup follows the real dependency closure"

echo
echo "menu --apply reaches the same fresh closure contract"
reset_fixture
menu_out="$(fixture_env bash "$FIX/scripts/runners/menu.sh" --apply 2>&1)"
menu_rc=$?
assert_eq "$menu_rc" "0" "menu --apply exits 0"
assert_eq "$(cat "$SENT/runtime-consumer" 2>/dev/null)" "8.4|8.4" \
    "menu applies languages/php with the default runtime"
assert_eq "$(cat "$SENT/web-consumer" 2>/dev/null)" "8.4|8.4" \
    "menu applies the dependent web owner with the same runtime"
assert_contains "$menu_out" "All selections applied" "menu reports the converged apply"

echo
echo "doctor --fix adopts a healthy owner added to an already-owned bundle"
reset_fixture
select_bundle web/stack
: > "$SENT/runtime-ready"
: > "$SENT/legacy-ready"
: > "$SENT/service-ready"
seed_marker runtime runtime-owner custom ./runtime-owner.sh
seed_marker web legacy-config custom ./legacy-config.sh
healthy_upgrade_out="$(run_doctor_fix 2>&1)"
healthy_upgrade_rc=$?
assert_eq "$healthy_upgrade_rc" "0" "doctor --fix exits 0 for a healthy upgraded host"
assert_file_exists "$STATE/web__service-convergence.env" \
    "doctor adopts the healthy new owner into the marker-owned bundle"
assert_contains "$healthy_upgrade_out" "stack/service-convergence: adopted ✓" \
    "doctor reports the exact new-owner adoption outcome"

echo
echo "doctor --fix repairs a broken owner added to an already-owned bundle"
reset_fixture
select_bundle web/stack
: > "$SENT/runtime-ready"
: > "$SENT/legacy-ready"
seed_marker runtime runtime-owner custom ./runtime-owner.sh
seed_marker web legacy-config custom ./legacy-config.sh
broken_upgrade_out="$(run_doctor_fix 2>&1)"
broken_upgrade_rc=$?
assert_eq "$broken_upgrade_rc" "0" "doctor --fix exits 0 after repairing the new owner"
assert_file_exists "$SENT/service-ready" \
    "doctor repairs the markerless service owner instead of false-green skipping it"
assert_file_exists "$STATE/web__service-convergence.env" \
    "doctor records the new owner only after repair and re-verification"
assert_contains "$broken_upgrade_out" "stack/service-convergence: repaired ✓" \
    "doctor reports the exact new-owner repair outcome"

echo
echo "update --full preserves the causal rc and a second run converges pending items"
reset_fixture
select_bundle demo/lifecycle
: > "$SENT/flaky-fail-once"

git init -q --bare "$ROOT/remote.git"
git -C "$FIX" init -q
git -C "$FIX" config user.name fixture
git -C "$FIX" config user.email fixture@example.test
git -C "$FIX" add setup.sh scripts topics
git -C "$FIX" commit -qm fixture
git -C "$FIX" branch -M main
git -C "$FIX" remote add origin "$ROOT/remote.git"
git -C "$FIX" push -q -u origin main
printf 'AUTO_UPDATE_REPOS=("%s")\n' "$FIX" > "$ROOT/auto-update.conf"

run_auto_update() {
    fixture_env env \
        AUTO_UPDATE_CONF="$ROOT/auto-update.conf" \
        AUTO_UPDATE_STATE_DIR="$UPDATE_STATE" \
        NO_COLOR=1 \
        bash "$FIX/scripts/runners/auto-update.sh" "$@"
}

first_full_out="$(run_auto_update --only mesh-workstation --full 2>&1)"
first_full_rc=$?
assert_eq "$first_full_rc" "78" \
    "update --full preserves the primary owner failure rc through setup and auto-update"
assert_contains "$first_full_out" "repair action failed (rc=78)" \
    "update --full keeps the causal engine diagnostic"
assert_eq "$(wc -l < "$SENT/stable-installs" 2>/dev/null | tr -d ' ')" "1" \
    "the resource before the failure converges once"
assert_eq "$(wc -l < "$SENT/flaky-attempts" 2>/dev/null | tr -d ' ')" "1" \
    "the failed resource records its first attempt"

second_full_out="$(run_auto_update --only mesh-workstation --full 2>&1)"
second_full_rc=$?
assert_eq "$second_full_rc" "0" "a second update --full converges the pending resource"
assert_eq "$(wc -l < "$SENT/stable-installs" 2>/dev/null | tr -d ' ')" "1" \
    "the second run does not reinstall the already-converged resource"
assert_eq "$(wc -l < "$SENT/flaky-attempts" 2>/dev/null | tr -d ' ')" "2" \
    "the second run retries the pending resource exactly once"
assert_file_exists "$STATE/demo__flaky.env" \
    "the pending resource receives its marker only after successful verification"
assert_contains "$second_full_out" "already present, verified" \
    "the rerun recognizes the previously converged resource"

echo
echo "update command preserves the first causal rc while still visiting both repos"
cat > "$ROOT/fake-update-motor.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${UPDATE_CALLS:?}"
case " $* " in
    *" --only mesh-workstation "*) exit 78 ;;
    *" --only mesh-identity "*) exit 1 ;;
esac
exit 0
SH
chmod +x "$ROOT/fake-update-motor.sh"
: > "$ROOT/update-calls"
fixture_env env \
    MOTOR="$ROOT/fake-update-motor.sh" \
    UPDATE_CALLS="$ROOT/update-calls" \
    UPDATE_MODULE="$UPDATE_MODULE" \
    bash -c '
        mesh_register_command() { :; }
        _mesh_fanout_validate_update() { :; }
        _mesh_self_alias() { printf fixture; }
        _resolve_companion() { printf "%s\n" "$MOTOR"; }
        _die() { printf "%s\n" "$*" >&2; exit 64; }
        source "$UPDATE_MODULE"
        cmd_update_run --full
    ' > "$ROOT/update-command.out" 2>&1
update_command_rc=$?
assert_eq "$update_command_rc" "78" \
    "mesh update keeps the first non-zero rc instead of bitwise-normalizing failures"
assert_eq "$(sed -n '1p' "$ROOT/update-calls")" "--only mesh-workstation --full" \
    "mesh update visits workstation first"
assert_eq "$(sed -n '2p' "$ROOT/update-calls")" "--only mesh-identity --full" \
    "mesh update still visits identity after the workstation failure"

echo
echo "update --force remains branch authorization, not an implicit full apply"
git -C "$FIX" checkout -qb feature
git -C "$FIX" push -q -u origin feature
: > "$SETUP_CALLS"
force_out="$(run_auto_update --only mesh-workstation --force 2>&1)"
force_rc=$?
assert_eq "$force_rc" "0" "update --force authorizes the current feature branch"
assert_contains "$force_out" "forçando update de mesh-workstation na branch feature" \
    "--force is consumed by the branch pre-flight"
assert_eq "$(cat "$SETUP_CALLS")" "" \
    "--force alone does not invoke setup or repair"

summary
