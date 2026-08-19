#!/usr/bin/env bash
# F2 T-001 — MESH_NO_MESH=1 aborts when a membership bundle is in the resolved
# selection/closure; writes no install marker. Unflagged apply of personal is
# unchanged. languages/php under no-mesh does not pull personal.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

ENGINE="$WS/scripts/lib/install-engine.sh"
assert_file_exists "$ENGINE" "install-engine.sh exists"
assert_file_contains "$ENGINE" 'no_mesh_omit_bundle' \
    "install-engine sources no-mesh membership deny"
assert_file_contains "$ENGINE" '_bundle_membership' \
    "install-engine reads BUNDLE_N_MEMBERSHIP"

ROOT="$(mktemp -d /tmp/no-mesh-engine-deny.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
TOPICS="$ROOT/topics"
ST="$ROOT/state/installed"
HOMEDIR="$ROOT/home"
mkdir -p "$TOPICS/personal" "$TOPICS/languages" "$TOPICS/foundation" "$ST" "$HOMEDIR"

cat > "$TOPICS/personal/manifest.yaml" <<'YAML'
topic:
  label: "Personal"
  order: 30
bundles:
  - name: personal
    label: "Personal"
    desc: "membership"
    membership: mesh
    items:
      - name: apply
        type: custom
        script: ./apply.sh
YAML
cat > "$TOPICS/personal/apply.sh" <<SH
OUT="${ROOT:?}"
check() { [[ -f "\$OUT/personal.done" ]]; }
install() { : > "\$OUT/personal.done"; : > "\$OUT/personal-INSTALL-RAN"; }
verify() { check; }
SH

cat > "$TOPICS/languages/manifest.yaml" <<'YAML'
topic:
  label: "Languages"
  order: 40
bundles:
  - name: php
    label: "PHP"
    desc: "php"
    items:
      - name: php
        type: custom
        script: ./php.sh
YAML
cat > "$TOPICS/languages/php.sh" <<SH
OUT="${ROOT:?}"
check() { [[ -f "\$OUT/php.done" ]]; }
install() { : > "\$OUT/php.done"; : > "\$OUT/php-INSTALL-RAN"; }
verify() { check; }
SH

cat > "$TOPICS/foundation/manifest.yaml" <<'YAML'
topic:
  label: "Foundation"
  order: 10
bundles:
  - name: base
    label: "Base"
    desc: "base"
    required: true
    items:
      - name: core
        type: custom
        script: ./core.sh
YAML
cat > "$TOPICS/foundation/core.sh" <<SH
OUT="${ROOT:?}"
check() { [[ -f "\$OUT/base.done" ]]; }
install() { : > "\$OUT/base.done"; }
verify() { check; }
SH

run_eng() {
    printf '%s\n' "$1" > "$ROOT/sel"
    HOME="$HOMEDIR" MESH_INSTALL_STATE_DIR="$ST" \
        bash "$ENGINE" \
        --topics-dir "$TOPICS" \
        --platform linux \
        --non-interactive \
        --selections "$ROOT/sel" \
        >"$ROOT/log" 2>&1
}

clean_sentinels() {
    rm -f "$ROOT"/personal-INSTALL-RAN "$ROOT"/php-INSTALL-RAN \
        "$ROOT"/personal.done "$ROOT"/php.done "$ROOT"/base.done \
        "$ST"/* 2>/dev/null || true
}

# 1) MESH_NO_MESH=1 + personal/personal → nonzero, no marker / no install
clean_sentinels
rc=0
MESH_NO_MESH=1 run_eng 'personal/personal' || rc=$?
assert_ne "$rc" "0" "MESH_NO_MESH=1 + personal/personal exits nonzero"
if [[ -f "$ROOT/personal-INSTALL-RAN" ]]; then
    fail "MESH_NO_MESH=1 + personal writes no install side effect"
else
    pass "MESH_NO_MESH=1 + personal writes no install side effect"
fi
if compgen -G "$ST/*" >/dev/null 2>&1; then
    fail "MESH_NO_MESH=1 + personal writes no install marker"
else
    pass "MESH_NO_MESH=1 + personal writes no install marker"
fi
assert_file_contains "$ROOT/log" 'no-mesh: refusing' \
    "deny log mentions no-mesh refusing membership"

# 2) MESH_NO_MESH=1 + languages/php → applies, no personal
clean_sentinels
rc=0
MESH_NO_MESH=1 run_eng 'languages/php' || rc=$?
assert_eq "$rc" "0" "MESH_NO_MESH=1 + languages/php exits 0"
assert_file_exists "$ROOT/php-INSTALL-RAN" "php install ran under no-mesh"
if [[ -f "$ROOT/personal-INSTALL-RAN" ]]; then
    fail "php under no-mesh does not pull personal"
else
    pass "php under no-mesh does not pull personal"
fi

# 3) unflagged apply of personal still works
clean_sentinels
unset MESH_NO_MESH || true
rc=0
run_eng 'personal/personal' || rc=$?
assert_eq "$rc" "0" "unflagged personal/personal exits 0"
assert_file_exists "$ROOT/personal-INSTALL-RAN" "unflagged personal install ran"

# 4) membership pulled via requires_bundles under no-mesh also aborts
cat > "$TOPICS/languages/manifest.yaml" <<'YAML'
topic:
  label: "Languages"
  order: 40
bundles:
  - name: php
    label: "PHP"
    desc: "php"
    requires_bundles:
      - personal/personal
    items:
      - name: php
        type: custom
        script: ./php.sh
YAML
clean_sentinels
rc=0
MESH_NO_MESH=1 run_eng 'languages/php' || rc=$?
assert_ne "$rc" "0" "no-mesh aborts when closure pulls membership personal"
if [[ -f "$ROOT/php-INSTALL-RAN" || -f "$ROOT/personal-INSTALL-RAN" ]]; then
    fail "closure deny mutates nothing"
else
    pass "closure deny mutates nothing"
fi

summary
