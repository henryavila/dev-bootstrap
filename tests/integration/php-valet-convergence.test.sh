#!/usr/bin/env bash
# tests/integration/php-valet-convergence.test.sh
#
# Red regression suite for the observed PHP -> Valet failure class: PHP can look
# present to check() while verify() emits startup warnings. Valet must not be the
# first actionable failure; the engine should repair PHP, re-verify it, then run
# Valet.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
ENGINE="$WS/scripts/lib/install-engine.sh"
PROD_VALET="$WS/topics/web/mac/valet.sh"
PROD_HARDENING="$WS/topics/web/mac/launchdaemon-hardening.sh"
# shellcheck source=../lib/assert.sh
# shellcheck disable=SC1091
source "$WS/tests/lib/assert.sh"

ROOT="$(mktemp -d -t php-valet-convergence.XXXXXX)"
cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT

TOPICS="$ROOT/topics"
STATE="$ROOT/state"
SENT="$ROOT/sentinels"
LOG="$ROOT/php-valet.log"
mkdir -p "$TOPICS/languages" "$TOPICS/web" "$STATE" "$SENT"

cat > "$STATE/languages__php-stack.env" <<'EOF'
MESH_ITEM_TOPIC="languages"
MESH_ITEM_NAME="php-stack"
MESH_ITEM_TYPE="custom"
MESH_ITEM_SPEC="./php-stack.sh"
MESH_ITEM_INSTALLED_AT="fixture"
EOF

cat > "$TOPICS/languages/manifest.yaml" <<'YAML'
topic:
  label: "Languages"
  order: 20
bundles:
  - name: php
    items:
      - name: php-stack
        type: custom
        script: ./php-stack.sh
YAML

cat > "$TOPICS/languages/php-stack.sh" <<SH
SENT_DIR="$SENT"
ORDER_FILE="$SENT/order"
check() { return 0; }
verify() {
    if [[ -f "\$SENT_DIR/php-repaired" ]]; then
        : > "\$SENT_DIR/php-clean"
        return 0
    fi
    printf 'Warning: PHP Startup: Unable to load dynamic library redis.so\n' >&2
    : > "\$SENT_DIR/php-startup-warning"
    return 1
}
install() { : > "\$SENT_DIR/php-install"; }
repair() {
    printf 'php-repair\n' >> "\$ORDER_FILE"
    : > "\$SENT_DIR/php-repaired"
}
SH

cat > "$TOPICS/web/manifest.yaml" <<'YAML'
topic:
  label: "Web"
  order: 70
bundles:
  - name: valet
    requires_bundles:
      - languages/php
    items:
      - name: valet
        type: custom
        script: ./valet.sh
YAML

cat > "$TOPICS/web/valet.sh" <<SH
SENT_DIR="$SENT"
ORDER_FILE="$SENT/order"
check() { return 1; }
install() {
    printf 'valet-install\n' >> "\$ORDER_FILE"
    if [[ ! -f "\$SENT_DIR/php-repaired" ]]; then
        printf 'web/valet: rc 67 because PHP emitted startup warnings\n' >&2
        return 67
    fi
    : > "\$SENT_DIR/valet-installed"
}
verify() {
    [[ -f "\$SENT_DIR/php-clean" ]] && [[ -f "\$SENT_DIR/valet-installed" ]]
}
SH

set +e
MESH_INSTALL_STATE_DIR="$STATE" bash "$ENGINE" --topics-dir "$TOPICS" --platform mac --bundle web/valet >"$LOG" 2>&1
rc=$?
set -u

order="$(cat "$SENT/order" 2>/dev/null || true)"
log_out="$(cat "$LOG" 2>/dev/null || true)"

assert_eq "$rc" "0" "PHP -> Valet convergence exits 0 after repairing PHP before Valet"
assert_file_exists "$SENT/php-startup-warning" "PHP verify captured the startup warning that check() missed"
assert_file_exists "$SENT/php-repaired" "PHP was repaired through its owner lifecycle"
assert_file_exists "$SENT/php-clean" "PHP was re-verified clean after repair"
assert_file_exists "$SENT/valet-installed" "Valet ran after PHP was repaired"
assert_eq "$(printf '%s\n' "$order" | sed -n '1p')" "php-repair" "first lifecycle action is PHP repair"
assert_eq "$(printf '%s\n' "$order" | sed -n '2p')" "valet-install" "second lifecycle action is Valet install"
assert_contains "$log_out" "PHP Startup" "engine output keeps the startup-warning root cause visible"

echo
echo "real mac bundle closure orders languages/php before web/valet"
real_mac_closure="$(bash "$ENGINE" --topics-dir "$WS/topics" --platform mac \
    --bundle web/valet --print-closure 2>"$ROOT/real-mac-closure.err")"
mac_php_pos="$(printf '%s\n' "$real_mac_closure" | awk '$0 == "languages/php" { print NR; exit }')"
mac_valet_pos="$(printf '%s\n' "$real_mac_closure" | awk '$0 == "web/valet" { print NR; exit }')"
assert_ne "$mac_php_pos" "" "real web/valet closure includes languages/php"
assert_ne "$mac_valet_pos" "" "real mac closure includes web/valet"
ASSERT_MSG="real mac closure places languages/php before web/valet" \
    assert_true "[ '${mac_php_pos:-0}' -gt 0 ] && [ '${mac_php_pos:-0}' -lt '${mac_valet_pos:-0}' ]"

make_valet_case() {
    local case_dir="$1"
    mkdir -p "$case_dir/bin" "$case_dir/home/.config/valet" \
        "$case_dir/vendor/bin" "$case_dir/code"
    printf '{"tld":"localhost"}\n' > "$case_dir/home/.config/valet/config.json"
    cat > "$case_dir/bin/composer" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == "global config --absolute bin-dir" ]]; then
    printf '%s\n' "$FAKE_VALET_BIN_DIR"
fi
SH
    cat > "$case_dir/bin/php" <<'SH'
#!/usr/bin/env bash
if [[ "${FAKE_PHP_MODE:-clean}" == "stderr" ]]; then
    printf 'Module ABI mismatch: extension was built for another PHP API\n' >&2
fi
printf 'PHP 8.4 fixture\n'
SH
    cat > "$case_dir/bin/sudo" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    cat > "$case_dir/vendor/bin/valet" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    --version) printf 'Laravel Valet fixture\n' ;;
    install)
        if [[ "${FAKE_VALET_MODE:-ok}" == "dyld" ]]; then
            printf 'dyld: Library not loaded: /Volumes/External/homebrew/opt/icu4c/lib/libicuio.dylib\n' >&2
            exit 78
        fi
        ;;
    tld) [[ "$#" -eq 1 ]] && printf 'localhost\n' ;;
    park) : ;;
esac
SH
    chmod +x "$case_dir/bin/composer" "$case_dir/bin/php" \
        "$case_dir/bin/sudo" "$case_dir/vendor/bin/valet"
}

run_valet_repair_case() {
    local case_dir="$1" mode="$2"
    HOME="$case_dir/home" \
    CODE_DIR="$case_dir/code" \
    PATH="$case_dir/bin:$PATH" \
    FAKE_VALET_BIN_DIR="$case_dir/vendor/bin" \
    FAKE_VALET_MODE="$mode" \
    VALET_STACK_VERIFY_ATTEMPTS=1 \
    bash -c '
        . "$1"
        _valet_external_unmounted() { return 1; }
        launchdaemon_harden_install() { return 0; }
        if [[ "$2" == "postcondition" ]]; then
            _valet_stack_ok() { VALET_STACK_FAILURE="php-fpm"; return 1; }
        fi
        FORCE_VALET_INSTALL=1 repair
    ' _ "$PROD_VALET" "$mode"
}

echo
echo "mac PHP preflight rejects any stderr before Valet repair"
PHP_STDERR_CASE="$ROOT/php-stderr-case"
make_valet_case "$PHP_STDERR_CASE"
php_stderr_out="$(HOME="$PHP_STDERR_CASE/home" PATH="$PHP_STDERR_CASE/bin:$PATH" \
    FAKE_PHP_MODE=stderr bash -c '. "$1"; _valet_php_probe_clean' _ "$PROD_VALET" 2>&1)"
php_stderr_rc=$?
assert_ne "$php_stderr_rc" "0" "alternate PHP stderr makes the Valet preflight fail"
assert_contains "$php_stderr_out" "PHP health check failed before Valet repair" \
    "PHP failure is classified before the web repair"
assert_contains "$php_stderr_out" "Module ABI mismatch" \
    "alternate PHP stderr remains visible and actionable"

echo
echo "mac Valet repair classifies dyld/LaunchDaemon activation separately"
DYLD_CASE="$ROOT/dyld-case"
make_valet_case "$DYLD_CASE"
dyld_out="$(run_valet_repair_case "$DYLD_CASE" dyld 2>&1)"
dyld_rc=$?
assert_ne "$dyld_rc" "0" "dyld failure keeps Valet repair red"
assert_contains "$dyld_out" "PHP health passed" "dyld diagnostic is distinct from dirty PHP"
assert_contains "$dyld_out" "LaunchDaemon/dyld/sandbox" \
    "dyld failure names the macOS service-activation class"
assert_contains "$dyld_out" "mesh doctor --fix" "dyld failure includes an actionable recovery command"

echo
echo "mac Valet repair proves the executable stack post-condition"
POST_CASE="$ROOT/postcondition-case"
make_valet_case "$POST_CASE"
post_out="$(run_valet_repair_case "$POST_CASE" postcondition 2>&1)"
post_rc=$?
assert_ne "$post_rc" "0" "successful valet command cannot publish convergence with a dead stack"
assert_contains "$post_out" "service post-condition failed after PHP health passed" \
    "post-condition failure is explicit"
assert_contains "$post_out" "php-fpm" "post-condition diagnostic names the failed component"

echo
echo "LaunchDaemon hardening propagates bootstrap failure with actionable diagnostics"
HARD_CASE="$ROOT/hardening-case"
mkdir -p "$HARD_CASE/bin" "$HARD_CASE/plists" "$HARD_CASE/logs"
: > "$HARD_CASE/plists/homebrew.mxcl.php.plist"
cat > "$HARD_CASE/bin/sudo" <<'SH'
#!/usr/bin/env bash
exec "$@"
SH
cat > "$HARD_CASE/bin/plistbuddy" <<'SH'
#!/usr/bin/env bash
case "$2" in
    Print*) printf '/Volumes/External/homebrew/var/log/php-fpm.log\n' ;;
    Set*|Add*) exit 0 ;;
esac
SH
cat > "$HARD_CASE/bin/launchctl" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    bootout) exit 0 ;;
    bootstrap)
        if [[ "${FAKE_LAUNCHCTL_MODE:-bootstrap-fail}" == "bootstrap-fail" ]]; then
            printf 'Bootstrap failed: 78: Operation not permitted by sandbox\n' >&2
            exit 78
        fi
        ;;
    print)
        case "${FAKE_LAUNCHCTL_MODE:-bootstrap-fail}" in
            waiting) printf 'state = waiting\n' ;;
            running) printf 'state = running\n' ;;
            *) exit 1 ;;
        esac
        ;;
esac
SH
chmod +x "$HARD_CASE/bin/sudo" "$HARD_CASE/bin/plistbuddy" "$HARD_CASE/bin/launchctl"
hardening_out="$(PATH="$HARD_CASE/bin:$PATH" \
    BREW_PREFIX=/Volumes/External/homebrew \
    MESH_LAUNCHDAEMON_DIR="$HARD_CASE/plists" \
    MESH_HOMEBREW_LOG_DIR="$HARD_CASE/logs" \
    MESH_PLISTBUDDY_BIN="$HARD_CASE/bin/plistbuddy" \
    MESH_LAUNCHCTL_BIN="$HARD_CASE/bin/launchctl" \
    MESH_LAUNCHDAEMON_VERIFY_ATTEMPTS=1 \
    FAKE_LAUNCHCTL_MODE=bootstrap-fail \
    bash -c '. "$1"; launchdaemon_harden_install' _ "$PROD_HARDENING" 2>&1)"
hardening_rc=$?
assert_ne "$hardening_rc" "0" "LaunchDaemon bootstrap rc is propagated"
assert_contains "$hardening_out" "LaunchDaemon/dyld/sandbox" \
    "hardening classifies the activation failure"
assert_contains "$hardening_out" "rc=78" "hardening reports the observed bootstrap rc"
assert_contains "$hardening_out" "mesh doctor --fix" \
    "hardening diagnostic includes the supported recovery command"

hardening_wait_out="$(PATH="$HARD_CASE/bin:$PATH" \
    BREW_PREFIX=/Volumes/External/homebrew \
    MESH_LAUNCHDAEMON_DIR="$HARD_CASE/plists" \
    MESH_HOMEBREW_LOG_DIR="$HARD_CASE/logs" \
    MESH_PLISTBUDDY_BIN="$HARD_CASE/bin/plistbuddy" \
    MESH_LAUNCHCTL_BIN="$HARD_CASE/bin/launchctl" \
    MESH_LAUNCHDAEMON_VERIFY_ATTEMPTS=1 \
    FAKE_LAUNCHCTL_MODE=waiting \
    bash -c '. "$1"; launchdaemon_harden_install' _ "$PROD_HARDENING" 2>&1)"
hardening_wait_rc=$?
assert_ne "$hardening_wait_rc" "0" \
    "bootstrap rc 0 cannot publish convergence while the job is not running"
assert_contains "$hardening_wait_out" "state = waiting" \
    "hardening preserves the observed non-running state"

PATH="$HARD_CASE/bin:$PATH" \
BREW_PREFIX=/Volumes/External/homebrew \
MESH_LAUNCHDAEMON_DIR="$HARD_CASE/plists" \
MESH_HOMEBREW_LOG_DIR="$HARD_CASE/logs" \
MESH_PLISTBUDDY_BIN="$HARD_CASE/bin/plistbuddy" \
MESH_LAUNCHCTL_BIN="$HARD_CASE/bin/launchctl" \
MESH_LAUNCHDAEMON_VERIFY_ATTEMPTS=1 \
FAKE_LAUNCHCTL_MODE=running \
bash -c '. "$1"; launchdaemon_harden_install' _ "$PROD_HARDENING" >/dev/null 2>&1
hardening_running_rc=$?
assert_eq "$hardening_running_rc" "0" \
    "bootstrap plus running post-condition publishes hardening convergence"

summary
