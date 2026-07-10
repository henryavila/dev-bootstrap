#!/usr/bin/env bash
# tests/integration/php-web-stack-convergence.test.sh
#
# WSL PHP -> nginx/php-fpm convergence contract. The web owner must run only
# after languages/php, reject any PHP/FPM stderr, preserve activation failures,
# and publish convergence only after the serving services are healthy.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
ENGINE="$WS/scripts/lib/install-engine.sh"
PROD_WSL="$WS/topics/web/wsl/nginx-php-fpm.sh"
WEB_MANIFEST="$WS/topics/web/manifest.yaml"
# shellcheck source=../lib/assert.sh
# shellcheck disable=SC1091
source "$WS/tests/lib/assert.sh"

ROOT="$(mktemp -d -t php-web-stack-convergence.XXXXXX)"
SOCKET_SERVER_PIDS=""
SOCKET_DIRS=""
cleanup() {
    local pid dir
    for pid in $SOCKET_SERVER_PIDS; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    for dir in $SOCKET_DIRS; do
        rm -rf "$dir"
    done
    rm -rf "$ROOT"
}
trap cleanup EXIT

echo "real WSL closure orders languages/php before web/nginx-php-fpm"
real_wsl_closure="$(bash "$ENGINE" --topics-dir "$WS/topics" --platform wsl \
    --bundle web/nginx-php-fpm --print-closure 2>"$ROOT/real-wsl-closure.err")"
wsl_php_pos="$(printf '%s\n' "$real_wsl_closure" | awk '$0 == "languages/php" { print NR; exit }')"
wsl_web_pos="$(printf '%s\n' "$real_wsl_closure" | awk '$0 == "web/nginx-php-fpm" { print NR; exit }')"
assert_ne "$wsl_php_pos" "" "real web/nginx-php-fpm closure includes languages/php"
assert_ne "$wsl_web_pos" "" "real WSL closure includes web/nginx-php-fpm"
ASSERT_MSG="real WSL closure places languages/php before web/nginx-php-fpm" \
    assert_true "[ '${wsl_php_pos:-0}' -gt 0 ] && [ '${wsl_php_pos:-0}' -lt '${wsl_web_pos:-0}' ]"

echo
echo "languages/php failure blocks the dependent web lifecycle"
DEP_TOPICS="$ROOT/dependency-topics"
DEP_STATE="$ROOT/dependency-state"
DEP_SENT="$ROOT/dependency-sentinels"
mkdir -p "$DEP_TOPICS/languages" "$DEP_TOPICS/web" "$DEP_STATE" "$DEP_SENT"
cat > "$DEP_TOPICS/languages/manifest.yaml" <<'YAML'
topic:
  label: Languages
  order: 20
bundles:
  - name: php
    items:
      - name: php-stack
        type: custom
        script: ./php-stack.sh
YAML
cat > "$DEP_TOPICS/languages/php-stack.sh" <<'SH'
check() { return 0; }
verify() {
    printf 'Module ABI mismatch: PHP CLI loaded an incompatible extension\n' >&2
    return 1
}
repair() { return 1; }
install() { return 1; }
SH
cat > "$DEP_TOPICS/web/manifest.yaml" <<'YAML'
topic:
  label: Web
  order: 70
bundles:
  - name: nginx-php-fpm
    requires_bundles:
      - languages/php
    items:
      - name: nginx-php-fpm
        type: custom
        script: ./nginx-php-fpm.sh
YAML
cat > "$DEP_TOPICS/web/nginx-php-fpm.sh" <<SH
check() { return 1; }
install() { : > "$DEP_SENT/web-activated"; }
verify() { return 0; }
SH
set +e
MESH_INSTALL_STATE_DIR="$DEP_STATE" bash "$ENGINE" --topics-dir "$DEP_TOPICS" \
    --platform wsl --bundle web/nginx-php-fpm >"$ROOT/dependency.log" 2>&1
dependency_rc=$?
set -u
dependency_out="$(cat "$ROOT/dependency.log")"
assert_ne "$dependency_rc" "0" "dirty PHP keeps the dependent WSL web bundle red"
assert_contains "$dependency_out" "Module ABI mismatch" \
    "engine output preserves the PHP root-cause diagnostic"
ASSERT_MSG="web activation never runs after PHP verify fails" \
    assert_false "[ -e '$DEP_SENT/web-activated' ]"

echo
echo "production manifest wires a final WSL convergence owner"
owner_line="$(awk '/^      - name: service-convergence$/ { print NR; exit }' "$WEB_MANIFEST")"
sites_line="$(awk '/^      - name: nginx-sites$/ { print NR; exit }' "$WEB_MANIFEST")"
owner_script="$(awk '
    /^      - name: service-convergence$/ { owner=1; next }
    owner && /^        script:/ { print; exit }
    owner && /^      - name:/ { exit }
' "$WEB_MANIFEST")"
assert_file_exists "$PROD_WSL" "production WSL nginx/php-fpm convergence owner exists"
assert_ne "$owner_line" "" "production web manifest includes the WSL convergence owner"
assert_contains "$owner_script" "./wsl/nginx-php-fpm.sh" \
    "production convergence item points at the WSL owner script"
ASSERT_MSG="WSL convergence owner runs after nginx site configuration" \
    assert_true "[ '${sites_line:-0}' -gt 0 ] && [ '${owner_line:-0}' -gt '${sites_line:-0}' ]"

# The first red run intentionally stops here when the owner has not been added
# yet. Once it exists, every case below executes the production script.
if [[ ! -r "$PROD_WSL" ]]; then
    summary
fi

make_wsl_case() {
    local case_dir="$1" socket_dir
    mkdir -p "$case_dir/bin"
    socket_dir="$(mktemp -d /tmp/mesh-fpm.XXXXXX)" || return 1
    SOCKET_DIRS="$SOCKET_DIRS $socket_dir"
    printf '%s\n' "$socket_dir" > "$case_dir/socket-dir"
    : > "$case_dir/calls"
    cat > "$case_dir/php-owner.sh" <<'SH'
verify() {
    local ver
    for ver in $PHP_VERSIONS; do
        "$PHP_CLI_BIN_DIR/php${ver}" -v >/dev/null || return $?
    done
}
SH
    cat > "$case_dir/bin/php8.4" <<'SH'
#!/usr/bin/env bash
if [[ "${FAKE_WSL_MODE:-ok}" == "php-stderr" ]]; then
    printf 'Module ABI mismatch: extension targets another PHP API\n' >&2
fi
printf 'PHP 8.4 fixture\n'
SH
    cp "$case_dir/bin/php8.4" "$case_dir/bin/php8.5"
    cat > "$case_dir/bin/php-fpm8.4" <<'SH'
#!/usr/bin/env bash
if [[ "${FAKE_WSL_MODE:-ok}" == "fpm-stderr" ]]; then
    printf 'Zend OPcache cannot be loaded twice in FPM\n' >&2
fi
printf 'PHP-FPM 8.4 fixture\n'
SH
    cp "$case_dir/bin/php-fpm8.4" "$case_dir/bin/php-fpm8.5"
    cat > "$case_dir/bin/nginx" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-t" ]]; then
    if [[ "${FAKE_WSL_MODE:-ok}" == "nginx-config-fail" ]]; then
        printf 'nginx: invalid directive in catchall-php.conf\n' >&2
        exit 2
    fi
    printf 'nginx: configuration file syntax is ok\n' >&2
    exit 0
fi
SH
    cat > "$case_dir/bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_WSL_CALLS"
case "${1:-}" in
    restart)
        if [[ "${FAKE_WSL_MODE:-ok}" == "activation-fail" && "${2:-}" == "php8.5-fpm" ]]; then
            printf 'Job for php8.5-fpm.service failed with result exit-code\n' >&2
            exit 78
        fi
        ;;
    is-active)
        unit="${*: -1}"
        if [[ "${FAKE_WSL_MODE:-ok}" == "fpm-inactive" && "$unit" == "php8.4-fpm" ]]; then
            printf 'inactive\n'
            exit 3
        fi
        if [[ "${FAKE_WSL_MODE:-ok}" == "nginx-inactive" && "$unit" == "nginx" ]]; then
            printf 'inactive\n'
            exit 3
        fi
        printf 'active\n'
        ;;
esac
SH
    cat > "$case_dir/bin/sudo" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "-v" ]] && exit 0
exec "$@"
SH
    chmod +x "$case_dir/bin/php8.4" "$case_dir/bin/php8.5" \
        "$case_dir/bin/php-fpm8.4" "$case_dir/bin/php-fpm8.5" \
        "$case_dir/bin/nginx" "$case_dir/bin/systemctl" "$case_dir/bin/sudo"
}

start_socket_fixture() {
    local case_dir="$1" tcp_mode="$2" pid n socket_dir
    socket_dir="$(cat "$case_dir/socket-dir")"
    rm -f "$case_dir/nginx-port"
    python3 - "$socket_dir/php8.4-fpm.sock" \
        "$socket_dir/php8.5-fpm.sock" "$case_dir/nginx-port" "$tcp_mode" \
        >"$case_dir/socket-server.log" 2>&1 <<'PY' &
import os
import select
import socket
import sys
import time

unix_paths = sys.argv[1:3]
port_file = sys.argv[3]
tcp_mode = sys.argv[4]
unix_servers = []
for path in unix_paths:
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(1)
    unix_servers.append(server)

tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
tcp.bind(("127.0.0.1", 0))
port = tcp.getsockname()[1]
if tcp_mode == "listen":
    tcp.listen(16)
    tcp.setblocking(False)
else:
    tcp.close()
    tcp = None

with open(port_file, "w", encoding="utf-8") as handle:
    handle.write(str(port))

while True:
    if tcp is None:
        time.sleep(0.1)
        continue
    ready, _, _ = select.select([tcp], [], [], 0.1)
    if ready:
        conn, _ = tcp.accept()
        conn.close()
PY
    pid=$!
    SOCKET_SERVER_PIDS="$SOCKET_SERVER_PIDS $pid"
    for ((n=1; n<=50; n++)); do
        [[ -s "$case_dir/nginx-port" ]] && return 0
        sleep 0.05
    done
    printf 'socket fixture failed to become ready:\n' >&2
    sed -n '1,8p' "$case_dir/socket-server.log" >&2
    return 1
}

run_wsl_owner() {
    local case_dir="$1" mode="$2" verb="${3:-install}" nginx_port socket_dir php_default
    nginx_port="$(cat "$case_dir/nginx-port" 2>/dev/null || printf '1')"
    socket_dir="$(cat "$case_dir/socket-dir")"
    php_default="${FAKE_TEST_PHP_DEFAULT:-8.5}"
    HOME="$case_dir/home" \
    PATH="$case_dir/bin:$PATH" \
    PHP_VERSIONS="8.4 8.5" \
    PHP_DEFAULT="$php_default" \
    PHP_CLI_BIN_DIR="$case_dir/bin" \
    PHP_FPM_BIN_DIR="$case_dir/bin" \
    PHP_FPM_RUN_DIR="$socket_dir" \
    MESH_PHP_OWNER_SCRIPT="$case_dir/php-owner.sh" \
    MESH_SYSTEMCTL_BIN="$case_dir/bin/systemctl" \
    MESH_NGINX_BIN="$case_dir/bin/nginx" \
    MESH_NGINX_HEALTH_HOST="127.0.0.1" \
    MESH_NGINX_HEALTH_PORT="$nginx_port" \
    WSL_WEB_VERIFY_ATTEMPTS=1 \
    FAKE_WSL_CALLS="$case_dir/calls" \
    FAKE_WSL_MODE="$mode" \
    bash -c '. "$1"; "$2"' _ "$PROD_WSL" "$verb"
}

echo
echo "WSL nginx default must belong to the declared PHP versions"
DEFAULT_CASE="$ROOT/default-version-case"
make_wsl_case "$DEFAULT_CASE"
default_out="$(FAKE_TEST_PHP_DEFAULT=8.6 run_wsl_owner "$DEFAULT_CASE" ok 2>&1)"
default_rc=$?
assert_ne "$default_rc" "0" "undeclared nginx PHP_DEFAULT keeps convergence red"
assert_contains "$default_out" "PHP_DEFAULT=8.6 is not present in PHP_VERSIONS" \
    "default-version drift has an objective diagnostic"
assert_eq "$(cat "$DEFAULT_CASE/calls")" "" \
    "invalid PHP_DEFAULT prevents service activation"

echo
echo "WSL PHP CLI stderr blocks service activation"
PHP_CASE="$ROOT/php-stderr-case"
make_wsl_case "$PHP_CASE"
php_out="$(run_wsl_owner "$PHP_CASE" php-stderr 2>&1)"
php_rc=$?
assert_ne "$php_rc" "0" "alternate PHP CLI stderr keeps WSL web repair red"
assert_contains "$php_out" "languages/php verify failed before service activation" \
    "dirty PHP is classified before the dependent service layer"
assert_contains "$php_out" "Module ABI mismatch" \
    "alternate PHP CLI diagnostic remains visible"
assert_eq "$(cat "$PHP_CASE/calls")" "" "dirty PHP prevents every systemd activation"

echo
echo "WSL PHP-FPM stderr blocks service activation"
FPM_STDERR_CASE="$ROOT/fpm-stderr-case"
make_wsl_case "$FPM_STDERR_CASE"
fpm_stderr_out="$(run_wsl_owner "$FPM_STDERR_CASE" fpm-stderr 2>&1)"
fpm_stderr_rc=$?
assert_ne "$fpm_stderr_rc" "0" "any PHP-FPM stderr keeps WSL web repair red"
assert_contains "$fpm_stderr_out" "php-fpm8.4 health failed before service activation" \
    "dirty FPM is classified before systemd activation"
assert_contains "$fpm_stderr_out" "Zend OPcache cannot be loaded twice" \
    "alternate PHP-FPM diagnostic remains visible"
assert_eq "$(cat "$FPM_STDERR_CASE/calls")" "" "dirty FPM prevents every systemd activation"

echo
echo "WSL activation rc is preserved and stops dependent activation"
ACT_CASE="$ROOT/activation-case"
make_wsl_case "$ACT_CASE"
activation_out="$(run_wsl_owner "$ACT_CASE" activation-fail 2>&1)"
activation_rc=$?
activation_calls="$(cat "$ACT_CASE/calls")"
assert_eq "$activation_rc" "78" "php-fpm systemd activation rc is propagated"
assert_contains "$activation_out" "activation failed for php8.5-fpm" \
    "activation failure names the failed service"
assert_contains "$activation_out" "rc=78" "activation diagnostic reports the observed rc"
assert_not_contains "$activation_calls" "restart nginx" \
    "nginx activation does not run after php-fpm activation fails"

NGINX_CONFIG_CASE="$ROOT/nginx-config-case"
make_wsl_case "$NGINX_CONFIG_CASE"
nginx_config_out="$(run_wsl_owner "$NGINX_CONFIG_CASE" nginx-config-fail 2>&1)"
nginx_config_rc=$?
assert_eq "$nginx_config_rc" "2" "nginx configuration-test rc is propagated"
assert_contains "$nginx_config_out" "nginx configuration validation failed (rc=2)" \
    "nginx configuration failure remains actionable"
assert_eq "$(cat "$NGINX_CONFIG_CASE/calls")" "" \
    "invalid nginx configuration prevents service activation"

echo
echo "WSL activation success still requires executable post-conditions"
POST_CASE="$ROOT/postcondition-case"
make_wsl_case "$POST_CASE"
post_out="$(run_wsl_owner "$POST_CASE" fpm-inactive 2>&1)"
post_rc=$?
assert_ne "$post_rc" "0" "restart rc 0 cannot publish convergence for inactive FPM"
assert_contains "$post_out" "service post-condition failed" \
    "post-condition failure is explicit"
assert_contains "$post_out" "php8.4-fpm" "post-condition diagnostic names inactive FPM"

SOCKET_CASE="$ROOT/socket-case"
make_wsl_case "$SOCKET_CASE"
socket_out="$(run_wsl_owner "$SOCKET_CASE" ok 2>&1)"
socket_rc=$?
assert_ne "$socket_rc" "0" "active FPM without its socket remains unhealthy"
assert_contains "$socket_out" "php8.4-fpm socket" \
    "missing FPM socket is an explicit post-condition failure"

NGINX_POST_CASE="$ROOT/nginx-postcondition-case"
make_wsl_case "$NGINX_POST_CASE"
start_socket_fixture "$NGINX_POST_CASE" listen || exit 2
nginx_post_out="$(run_wsl_owner "$NGINX_POST_CASE" nginx-inactive 2>&1)"
nginx_post_rc=$?
assert_ne "$nginx_post_rc" "0" "restart rc 0 cannot publish convergence for inactive nginx"
assert_contains "$nginx_post_out" "service post-condition failed" \
    "nginx post-condition failure is explicit"
assert_contains "$nginx_post_out" "nginx" "post-condition diagnostic names inactive nginx"

NGINX_LISTENER_CASE="$ROOT/nginx-listener-case"
make_wsl_case "$NGINX_LISTENER_CASE"
start_socket_fixture "$NGINX_LISTENER_CASE" closed || exit 2
nginx_listener_out="$(run_wsl_owner "$NGINX_LISTENER_CASE" ok 2>&1)"
nginx_listener_rc=$?
assert_ne "$nginx_listener_rc" "0" \
    "active nginx without a listener cannot publish convergence"
assert_contains "$nginx_listener_out" "nginx listener" \
    "missing nginx listener is an explicit post-condition failure"

echo
echo "WSL healthy services converge without changing boot policy"
OK_CASE="$ROOT/ok-case"
make_wsl_case "$OK_CASE"
start_socket_fixture "$OK_CASE" listen || exit 2
ok_out="$(run_wsl_owner "$OK_CASE" ok 2>&1)"
ok_rc=$?
install_calls="$(cat "$OK_CASE/calls")"
: > "$OK_CASE/calls"
verify_out="$(run_wsl_owner "$OK_CASE" ok verify 2>&1)"
verify_rc=$?
verify_calls="$(cat "$OK_CASE/calls")"
assert_eq "$ok_rc" "0" "clean PHP plus healthy FPM/nginx publishes convergence"
assert_eq "$verify_rc" "0" "healthy WSL stack passes the read-only verifier"
assert_contains "$install_calls" "restart php8.4-fpm" "repair activates declared php-fpm"
assert_contains "$install_calls" "restart php8.5-fpm" \
    "repair activates every declared php-fpm version"
assert_contains "$install_calls" "restart nginx" "repair activates nginx after php-fpm"
fpm84_pos="$(printf '%s\n' "$install_calls" | awk '$0 == "restart php8.4-fpm" { print NR; exit }')"
fpm85_pos="$(printf '%s\n' "$install_calls" | awk '$0 == "restart php8.5-fpm" { print NR; exit }')"
nginx_pos="$(printf '%s\n' "$install_calls" | awk '$0 == "restart nginx" { print NR; exit }')"
ASSERT_MSG="repair activates every declared FPM before nginx" \
    assert_true "[ '${fpm84_pos:-0}' -lt '${fpm85_pos:-0}' ] && [ '${fpm85_pos:-0}' -lt '${nginx_pos:-0}' ]"
assert_not_contains "$install_calls$verify_calls" "enable" \
    "WSL convergence leaves boot-enable policy unchanged"
assert_not_contains "$verify_calls" "restart" "WSL verifier is read-only"
assert_not_contains "$ok_out$verify_out" "health failed" \
    "healthy convergence emits no causal failure diagnostic"

summary
