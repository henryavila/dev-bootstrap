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

summary
