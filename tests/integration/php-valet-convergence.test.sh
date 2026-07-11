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

run_valet_hardening_rc_case() {
    local case_dir="$1" verb="$2" fail_on_call="$3"
    HOME="$case_dir/home" \
    CODE_DIR="$case_dir/code" \
    PATH="$case_dir/bin:$PATH" \
    FAKE_VALET_BIN_DIR="$case_dir/vendor/bin" \
    VALET_STACK_VERIFY_ATTEMPTS=1 \
    bash -c '
        . "$1"
        _valet_external_unmounted() { return 1; }
        _valet_php_probe_clean() { return 0; }
        _hardening_calls=0
        _hardening_fail_on_call="$3"
        launchdaemon_harden_install() {
            _hardening_calls=$((_hardening_calls + 1))
            if [[ "$_hardening_calls" -eq "$_hardening_fail_on_call" ]]; then
                return 78
            fi
            return 0
        }
        FORCE_VALET_INSTALL=1 "$2"
    ' _ "$PROD_VALET" "$verb" "$fail_on_call"
}

echo
echo "Valet preserves LaunchDaemon rc 78 through install and repair"
RC_CASE="$ROOT/valet-hardening-rc-case"
make_valet_case "$RC_CASE"

run_valet_hardening_rc_case "$RC_CASE" install 1 >/dev/null 2>&1
valet_pre_hardening_rc=$?
assert_eq "$valet_pre_hardening_rc" "78" \
    "Valet install preserves rc 78 from pre-install LaunchDaemon hardening"

run_valet_hardening_rc_case "$RC_CASE" install 2 >/dev/null 2>&1
valet_post_hardening_rc=$?
assert_eq "$valet_post_hardening_rc" "78" \
    "Valet install preserves rc 78 from post-install LaunchDaemon hardening"

run_valet_hardening_rc_case "$RC_CASE" repair 1 >/dev/null 2>&1
valet_repair_hardening_rc=$?
assert_eq "$valet_repair_hardening_rc" "78" \
    "Valet repair preserves rc 78 from LaunchDaemon hardening"

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
plist="$3"
case "$2" in
    "Print :StandardErrorPath")
        if [[ -r "${plist}.err" ]]; then
            cat "${plist}.err"
        else
            printf '/Volumes/External/homebrew/var/log/php-fpm.log\n'
        fi
        ;;
    "Print :StandardOutPath")
        if [[ -r "${plist}.out" ]]; then
            cat "${plist}.out"
        else
            printf '/Volumes/External/homebrew/var/log/php-fpm.log\n'
        fi
        ;;
    "Set :StandardErrorPath "*|"Add :StandardErrorPath string "*)
        value="${2#*StandardErrorPath }"; value="${value#string }"
        printf '%s\n' "$value" > "${plist}.err"
        ;;
    "Set :StandardOutPath "*)
        value="${2#Set :StandardOutPath }"
        printf '%s\n' "$value" > "${plist}.out"
        ;;
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
    MESH_LAUNCHDAEMON_STATE_DIR="$HARD_CASE/state" \
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
    MESH_LAUNCHDAEMON_STATE_DIR="$HARD_CASE/state" \
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
MESH_LAUNCHDAEMON_STATE_DIR="$HARD_CASE/state" \
MESH_LAUNCHDAEMON_VERIFY_ATTEMPTS=1 \
FAKE_LAUNCHCTL_MODE=running \
bash -c '. "$1"; launchdaemon_harden_install' _ "$PROD_HARDENING" >/dev/null 2>&1
hardening_running_rc=$?
assert_eq "$hardening_running_rc" "0" \
    "bootstrap plus running post-condition publishes hardening convergence"

echo
echo "LaunchDaemon check validates optional StandardOutPath"
HARD_CHECK_CASE="$ROOT/hardening-check-case"
mkdir -p "$HARD_CHECK_CASE/bin" "$HARD_CHECK_CASE/plists" \
    "$HARD_CHECK_CASE/logs" "$HARD_CHECK_CASE/state"
: > "$HARD_CHECK_CASE/plists/homebrew.mxcl.php.plist"
cat > "$HARD_CHECK_CASE/bin/plistbuddy" <<'SH'
#!/usr/bin/env bash
case "$2" in
    "Print :StandardErrorPath") printf '%s/php.log\n' "$FAKE_SAFE_LOG_DIR" ;;
    "Print :StandardOutPath")
        case "$FAKE_OUT_MODE" in
            absent) exit 1 ;;
            safe) printf '%s/php.log\n' "$FAKE_SAFE_LOG_DIR" ;;
            external) printf '/Volumes/External/homebrew/var/log/php.log\n' ;;
        esac
        ;;
esac
SH
cat > "$HARD_CHECK_CASE/bin/launchctl" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "print" ]] && {
    printf 'state = %s\n' "${FAKE_JOB_STATE:-running}"
    exit 0
}
exit 0
SH
chmod +x "$HARD_CHECK_CASE/bin/plistbuddy" "$HARD_CHECK_CASE/bin/launchctl"

run_hardening_check_case() {
    local mode="$1" state="${2:-running}"
    PATH="$HARD_CHECK_CASE/bin:$PATH" \
    BREW_PREFIX=/Volumes/External/homebrew \
    MESH_LAUNCHDAEMON_DIR="$HARD_CHECK_CASE/plists" \
    MESH_HOMEBREW_LOG_DIR="$HARD_CHECK_CASE/logs" \
    MESH_PLISTBUDDY_BIN="$HARD_CHECK_CASE/bin/plistbuddy" \
    MESH_LAUNCHCTL_BIN="$HARD_CHECK_CASE/bin/launchctl" \
    MESH_LAUNCHDAEMON_STATE_DIR="$HARD_CHECK_CASE/state" \
    FAKE_SAFE_LOG_DIR="$HARD_CHECK_CASE/logs" \
    FAKE_OUT_MODE="$mode" \
    FAKE_JOB_STATE="$state" \
    bash -c '. "$1"; launchdaemon_harden_check' _ "$PROD_HARDENING"
}

run_hardening_check_case absent >/dev/null 2>&1
hardening_out_absent_rc=$?
assert_eq "$hardening_out_absent_rc" "0" \
    "hardening check accepts an absent StandardOutPath"

run_hardening_check_case safe >/dev/null 2>&1
hardening_out_safe_rc=$?
assert_eq "$hardening_out_safe_rc" "0" \
    "hardening check accepts a safe StandardOutPath"

run_hardening_check_case external >/dev/null 2>&1
hardening_out_external_rc=$?
assert_ne "$hardening_out_external_rc" "0" \
    "hardening check rejects an external StandardOutPath"

run_hardening_check_case safe waiting >/dev/null 2>&1
hardening_safe_stopped_rc=$?
assert_eq "$hardening_safe_stopped_rc" "0" \
    "standalone hardening check owns safe plist state, not generic Valet service liveness"

: > "$HARD_CHECK_CASE/state/php.pending"
run_hardening_check_case safe waiting >/dev/null 2>&1
hardening_pending_rc=$?
assert_ne "$hardening_pending_rc" "0" \
    "pending activation remains red even when the on-disk plist is already safe"
rm -f "$HARD_CHECK_CASE/state/php.pending"

echo
echo "LaunchDaemon hardening is forward-only and retryable per service"
TX_CASE="$ROOT/hardening-transaction-case"
mkdir -p "$TX_CASE/bin" "$TX_CASE/plists" "$TX_CASE/logs" \
    "$TX_CASE/runtime" "$TX_CASE/pending"
cat > "$TX_CASE/bin/sudo" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "-v" ]] && exit 0
exec "$@"
SH
cat > "$TX_CASE/bin/plistbuddy" <<'SH'
#!/usr/bin/env bash
cmd="$2"
plist="$3"

read_value() {
    local key="$1"
    sed -n "s/^${key}=//p" "$plist" | sed -n '1p'
}

write_value() {
    local key="$1" value="$2" tmp="${plist}.tmp.$$"
    grep -v "^${key}=" "$plist" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$plist"
}

case "$cmd" in
    "Print :StandardErrorPath")
        value="$(read_value ERR)"; [[ -n "$value" ]] || exit 1; printf '%s\n' "$value"
        ;;
    "Print :StandardOutPath")
        value="$(read_value OUT)"; [[ -n "$value" ]] || exit 1; printf '%s\n' "$value"
        ;;
    "Set :StandardErrorPath "*|"Add :StandardErrorPath string "*)
        value="${cmd#*StandardErrorPath }"; value="${value#string }"; write_value ERR "$value"
        ;;
    "Set :StandardOutPath "*)
        value="${cmd#Set :StandardOutPath }"; write_value OUT "$value"
        ;;
esac
SH
cat > "$TX_CASE/bin/launchctl" <<'SH'
#!/usr/bin/env bash
command_name="${1:-}"
printf '%s\n' "$*" >> "$FAKE_LAUNCHCTL_CALLS"

service_from_label() {
    local label="$1"
    label="${label##*/homebrew.mxcl.}"
    printf '%s\n' "$label"
}

service_from_plist() {
    local name
    name="$(basename "$1")"
    name="${name#homebrew.mxcl.}"
    printf '%s\n' "${name%.plist}"
}

case "$command_name" in
    bootout)
        svc="$(service_from_label "${2:-}")"
        if [[ "$FAKE_LAUNCHCTL_MODE" == "bootout-fail" ]]; then
            printf 'Boot-out failed: 78\n' >&2
            exit 78
        fi
        printf 'unloaded\n' > "$FAKE_LAUNCHCTL_STATE_DIR/$svc"
        ;;
    bootstrap)
        svc="$(service_from_plist "${3:-}")"
        count=0
        [[ -r "$FAKE_LAUNCHCTL_COUNT" ]] && count="$(cat "$FAKE_LAUNCHCTL_COUNT")"
        count=$((count + 1))
        printf '%s\n' "$count" > "$FAKE_LAUNCHCTL_COUNT"
        case "$FAKE_LAUNCHCTL_MODE" in
            retry-success)
                if [[ "$count" -eq 1 ]]; then
                    printf 'Bootstrap failed: 78: transient sandbox failure\n' >&2
                    exit 78
                fi
                ;;
            persistent)
                printf 'Bootstrap failed: 78: persistent sandbox failure\n' >&2
                exit 78
                ;;
            persistent-nginx)
                if [[ "$svc" == "nginx" ]]; then
                    printf 'Bootstrap failed: 78: nginx sandbox failure\n' >&2
                    exit 78
                fi
                ;;
            waiting)
                printf 'waiting\n' > "$FAKE_LAUNCHCTL_STATE_DIR/$svc"
                exit 0
                ;;
        esac
        printf 'running\n' > "$FAKE_LAUNCHCTL_STATE_DIR/$svc"
        ;;
    print)
        svc="$(service_from_label "${2:-}")"
        state=""
        [[ -r "$FAKE_LAUNCHCTL_STATE_DIR/$svc" ]] \
            && state="$(cat "$FAKE_LAUNCHCTL_STATE_DIR/$svc")"
        case "$state" in
            running) printf 'state = running\n'; exit 0 ;;
            waiting) printf 'state = waiting\n'; exit 0 ;;
            scheduled) printf 'state = spawn scheduled\n'; exit 0 ;;
            *) exit 1 ;;
        esac
        ;;
esac
SH
chmod +x "$TX_CASE/bin/sudo" "$TX_CASE/bin/plistbuddy" "$TX_CASE/bin/launchctl"

seed_tx_plist() {
    local svc="$1"
    printf 'ERR=/Volumes/External/homebrew/var/log/%s.log\nOUT=/Volumes/External/homebrew/var/log/%s.log\n' \
        "$svc" "$svc" > "$TX_CASE/plists/homebrew.mxcl.${svc}.plist"
    printf 'running\n' > "$TX_CASE/runtime/$svc"
}

reset_tx_case() {
    rm -f "$TX_CASE/plists"/* "$TX_CASE/runtime"/* "$TX_CASE/pending"/* \
        "$TX_CASE/calls" "$TX_CASE/count"
    : > "$TX_CASE/calls"
    printf '0\n' > "$TX_CASE/count"
}

run_tx_hardening() {
    local mode="$1"
    PATH="$TX_CASE/bin:$PATH" \
    BREW_PREFIX=/Volumes/External/homebrew \
    MESH_LAUNCHDAEMON_DIR="$TX_CASE/plists" \
    MESH_HOMEBREW_LOG_DIR="$TX_CASE/logs" \
    MESH_PLISTBUDDY_BIN="$TX_CASE/bin/plistbuddy" \
    MESH_LAUNCHCTL_BIN="$TX_CASE/bin/launchctl" \
    MESH_LAUNCHDAEMON_STATE_DIR="$TX_CASE/pending" \
    MESH_LAUNCHDAEMON_VERIFY_ATTEMPTS=1 \
    FAKE_LAUNCHCTL_MODE="$mode" \
    FAKE_LAUNCHCTL_CALLS="$TX_CASE/calls" \
    FAKE_LAUNCHCTL_COUNT="$TX_CASE/count" \
    FAKE_LAUNCHCTL_STATE_DIR="$TX_CASE/runtime" \
    bash -c '. "$1"; launchdaemon_harden_install' _ "$PROD_HARDENING"
}

reset_tx_case
seed_tx_plist php
retry_out="$(run_tx_hardening retry-success 2>&1)"
retry_rc=$?
assert_eq "$retry_rc" "0" \
    "transient bootstrap rc 78 is recovered by one hardened-plist retry"
assert_eq "$(cat "$TX_CASE/count")" "2" \
    "bootstrap recovery performs exactly one retry"
assert_contains "$retry_out" "recovery succeeded" \
    "bootstrap retry reports successful recovery"

reset_tx_case
seed_tx_plist php
persistent_out="$(run_tx_hardening persistent 2>&1)"
persistent_rc=$?
persistent_count="$(cat "$TX_CASE/count")"
assert_eq "$persistent_rc" "78" \
    "persistent bootstrap failure preserves the primary rc 78"
assert_contains "$persistent_out" "recovery failed" \
    "persistent bootstrap failure reports recovery failure"
assert_contains "$persistent_out" "primary rc=78" \
    "persistent bootstrap failure identifies the preserved primary rc"

run_tx_hardening success > "$TX_CASE/reexec.out" 2>&1
reexec_rc=$?
reexec_count="$(cat "$TX_CASE/count")"
assert_eq "$reexec_rc" "0" \
    "re-execution converges a hardened plist left by activation failure"
ASSERT_MSG="re-execution retries bootstrap even when plist paths are already hardened" \
    assert_true "[ '$reexec_count' -gt '$persistent_count' ]"
assert_eq "$(cat "$TX_CASE/runtime/php")" "running" \
    "re-execution proves the recovered service is running"

reset_tx_case
seed_tx_plist php
bootout_out="$(run_tx_hardening bootout-fail 2>&1)"
bootout_rc=$?
assert_eq "$bootout_rc" "78" \
    "persistent bootout failure preserves the primary rc 78"
assert_contains "$bootout_out" "recovery failed" \
    "persistent bootout failure reports recovery failure"
run_tx_hardening success > "$TX_CASE/bootout-reexec.out" 2>&1
bootout_reexec_rc=$?
assert_eq "$bootout_reexec_rc" "0" \
    "re-execution retries a pending service after bootout failure"
assert_eq "$(cat "$TX_CASE/runtime/php")" "running" \
    "bootout-failure re-execution proves the service running"

reset_tx_case
seed_tx_plist php
waiting_tx_out="$(run_tx_hardening waiting 2>&1)"
waiting_tx_rc=$?
assert_eq "$waiting_tx_rc" "1" \
    "persistent non-running launchctl state preserves the primary wait rc"
assert_contains "$waiting_tx_out" "recovery failed" \
    "persistent wait failure reports recovery failure"
run_tx_hardening success > "$TX_CASE/waiting-reexec.out" 2>&1
waiting_reexec_rc=$?
assert_eq "$waiting_reexec_rc" "0" \
    "re-execution retries a pending service after wait failure"
assert_eq "$(cat "$TX_CASE/runtime/php")" "running" \
    "wait-failure re-execution proves the service running"

reset_tx_case
seed_tx_plist php
seed_tx_plist nginx
seed_tx_plist dnsmasq
run_tx_hardening persistent-nginx > "$TX_CASE/multisvc.out" 2>&1
multisvc_rc=$?
assert_eq "$multisvc_rc" "78" \
    "per-service hardening preserves nginx primary rc 78"
assert_contains "$(cat "$TX_CASE/plists/homebrew.mxcl.php.plist")" \
    "ERR=$TX_CASE/logs/php.log" \
    "php commits its hardened plist before nginx begins"
assert_contains "$(cat "$TX_CASE/plists/homebrew.mxcl.nginx.plist")" \
    "ERR=$TX_CASE/logs/nginx.log" \
    "nginx keeps its forward-only hardened plist after activation failure"
assert_contains "$(cat "$TX_CASE/plists/homebrew.mxcl.dnsmasq.plist")" \
    "ERR=/Volumes/External/homebrew/var/log/dnsmasq.log" \
    "dnsmasq remains untouched after nginx fails"
assert_not_contains "$(cat "$TX_CASE/calls")" "homebrew.mxcl.dnsmasq" \
    "dnsmasq activation does not start before nginx proves running"

summary
