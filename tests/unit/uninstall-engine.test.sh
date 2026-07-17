#!/usr/bin/env bash
# Unit tests for scripts/lib/uninstall-engine.sh (manifest v2 bundle engine).
# Covers: reverse-topological order (dependents before deps), reverse item
# order within a bundle, when: gating (skip never-installed items), custom
# uninstall() dispatch, install-marker removal, and NO requires_bundles closure
# (uninstalling a dependent must not auto-remove its dep).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
ENGINE="$WS/scripts/lib/uninstall-engine.sh"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected: [$expected], got: [$actual])" >&2; fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TD="$TMP/topics"; ST="$TMP/state/installed"; OUT="$TMP/out"
PARAMS="$TMP/params.env"
mkdir -p "$TD/t1" "$TD/t2" "$ST" "$OUT"
printf 'T2_FLAG=1\n' > "$PARAMS"

cat > "$TD/t1/manifest.yaml" <<'YAML'
topic:
  label: "T1"
  order: 10
bundles:
  - name: base
    label: "Base"
    desc: "dep of t2/dependent"
    items:
      - name: b1
        type: custom
        script: ./b1.sh
YAML
cat > "$TD/t2/manifest.yaml" <<'YAML'
topic:
  label: "T2"
  order: 20
bundles:
  - name: dependent
    label: "Dependent"
    desc: "requires t1/base"
    requires_bundles:
      - t1/base
    options:
      - name: flag
        type: toggle
        label: "Flag"
        env: T2_FLAG
        default: false
    items:
      - name: d1
        type: custom
        script: ./d1.sh
      - name: d2
        type: custom
        script: ./d2.sh
      - name: dgate
        type: custom
        script: ./dgate.sh
        when: option.flag
YAML

_mk() {  # $1 dir, $2 name
    cat > "$1/$2.sh" <<SH
TAG="$2"; OUT="\${ENGTEST_OUT:?}"
check()     { [ -f "\$OUT/\$TAG.done" ]; }
install()   { : > "\$OUT/\$TAG.done"; }
verify()    { check; }
uninstall() { rm -f "\$OUT/\$TAG.done"; echo "\$TAG" >> "\$OUT/ulog.txt"; }
SH
    chmod +x "$1/$2.sh"
}
_mk "$TD/t1" b1
_mk "$TD/t2" d1
_mk "$TD/t2" d2
_mk "$TD/t2" dgate

# Seed install state (as if installed): markers + .done files for all items.
seed() {
    rm -rf "$ST" "$OUT"; mkdir -p "$ST" "$OUT"
    ENGTEST_OUT="$OUT" MESH_INSTALL_STATE_DIR="$ST" \
        bash "$WS/scripts/lib/install-engine.sh" --topics-dir "$TD" --params "$PARAMS" \
        --platform mac --bundle t1/base --bundle t2/dependent >/dev/null 2>&1
}

# ── Test 1: reverse topo + reverse item order + custom uninstall() ──
seed
printf 't1/base\nt2/dependent\n' > "$TMP/sel.list"
out="$(ENGTEST_OUT="$OUT" MESH_INSTALL_STATE_DIR="$ST" \
    bash "$ENGINE" --topics-dir "$TD" --params "$PARAMS" --platform mac \
    --selections "$TMP/sel.list" 2>&1)"
# dependent (t2, order 20) removed before base (t1, order 10); within dependent,
# items reverse: dgate, d2, d1; then base: b1.
assert "reverse order (deps last, items reversed)" "dgate
d2
d1
b1" "$(cat "$OUT/ulog.txt")"
assert "markers cleared after uninstall" "" "$(ls "$ST" 2>/dev/null)"

# ── Test 2: NO closure — uninstalling only the dependent leaves the dep's marker ──
seed
printf 't2/dependent\n' > "$TMP/sel.dep"
ENGTEST_OUT="$OUT" MESH_INSTALL_STATE_DIR="$ST" \
    bash "$ENGINE" --topics-dir "$TD" --params "$PARAMS" --platform mac \
    --selections "$TMP/sel.dep" >/dev/null 2>&1
assert "no closure: t1/base marker survives" "yes" "$(test -f "$ST/t1__b1.env" && echo yes || echo no)"
assert "no closure: t2 dependent markers gone" "no" "$(test -f "$ST/t2__d1.env" && echo yes || echo no)"

# ── Test 3: when: option false → never-installed item skipped on uninstall ──
seed
: > "$PARAMS"   # flag now off → dgate considered not-installed
out="$(ENGTEST_OUT="$OUT" MESH_INSTALL_STATE_DIR="$ST" \
    bash "$ENGINE" --topics-dir "$TD" --params "$PARAMS" --platform mac \
    --selections "$TMP/sel.dep" 2>&1)"
assert "when off: dgate skipped on uninstall" "yes" "$(echo "$out" | grep -q 'dgate: skip uninstall (when: option.flag off)' && echo yes || echo no)"

# ── Test 4: dry-run performs no removal ──
seed
ENGTEST_OUT="$OUT" MESH_INSTALL_STATE_DIR="$ST" \
    bash "$ENGINE" --topics-dir "$TD" --params "$PARAMS" --platform mac \
    --selections "$TMP/sel.dep" --dry-run >/dev/null 2>&1
assert "dry-run: marker still present" "yes" "$(test -f "$ST/t2__d1.env" && echo yes || echo no)"

# ── Test 5: custom item with NO uninstall() keeps its marker (D4 honesty) ──
# Regression for the ngrok bug: dropping the marker unconditionally made the menu
# report a still-installed item as removed. A script lacking uninstall() must now
# keep its marker AND warn.
mkdir -p "$TD/t3"
cat > "$TD/t3/manifest.yaml" <<'YAML'
topic:
  label: "T3"
  order: 30
bundles:
  - name: noop
    label: "Noop"
    desc: "custom item lacking uninstall()"
    items:
      - name: x1
        type: custom
        script: ./x1.sh
YAML
cat > "$TD/t3/x1.sh" <<'SH'
check()    { [ -f "${ENGTEST_OUT:?}/x1.done" ]; }
install()  { : > "${ENGTEST_OUT:?}/x1.done"; }
verify()   { check; }
rollback() { :; }
SH
chmod +x "$TD/t3/x1.sh"
rm -rf "$ST" "$OUT"; mkdir -p "$ST" "$OUT"
ENGTEST_OUT="$OUT" MESH_INSTALL_STATE_DIR="$ST" \
    bash "$WS/scripts/lib/install-engine.sh" --topics-dir "$TD" --params "$PARAMS" \
    --platform mac --bundle t3/noop >/dev/null 2>&1
printf 't3/noop\n' > "$TMP/sel.t3"
out="$(ENGTEST_OUT="$OUT" MESH_INSTALL_STATE_DIR="$ST" \
    bash "$ENGINE" --topics-dir "$TD" --params "$PARAMS" --platform mac \
    --selections "$TMP/sel.t3" 2>&1)"
assert "no-uninstall(): marker kept (no false 'removed')" "yes" "$(test -f "$ST/t3__x1.env" && echo yes || echo no)"
assert "no-uninstall(): warns about missing uninstall()" "yes" "$(echo "$out" | grep -q 'defines no uninstall()' && echo yes || echo no)"

# ── Test 6: custom uninstall() that FAILS keeps its marker (removal unconfirmed) ──
cat > "$TD/t3/x1.sh" <<'SH'
check()     { [ -f "${ENGTEST_OUT:?}/x1.done" ]; }
install()   { : > "${ENGTEST_OUT:?}/x1.done"; }
verify()    { check; }
rollback()  { :; }
uninstall() { return 3; }   # claims failure → marker must survive
SH
rm -rf "$ST" "$OUT"; mkdir -p "$ST" "$OUT"
ENGTEST_OUT="$OUT" MESH_INSTALL_STATE_DIR="$ST" \
    bash "$WS/scripts/lib/install-engine.sh" --topics-dir "$TD" --params "$PARAMS" \
    --platform mac --bundle t3/noop >/dev/null 2>&1
out="$(ENGTEST_OUT="$OUT" MESH_INSTALL_STATE_DIR="$ST" \
    bash "$ENGINE" --topics-dir "$TD" --params "$PARAMS" --platform mac \
    --selections "$TMP/sel.t3" 2>&1)"
assert "failed uninstall(): marker kept" "yes" "$(test -f "$ST/t3__x1.env" && echo yes || echo no)"

# ── Test 7: repeated uninstall without markers reports zero changed items ──
printf 'T2_FLAG=1\n' > "$PARAMS"
seed
printf 't2/dependent\n' > "$TMP/sel.dep"
ENGTEST_OUT="$OUT" MESH_INSTALL_STATE_DIR="$ST" \
    bash "$ENGINE" --topics-dir "$TD" --params "$PARAMS" --platform mac \
    --selections "$TMP/sel.dep" >/dev/null 2>&1
out="$(ENGTEST_OUT="$OUT" MESH_INSTALL_STATE_DIR="$ST" \
    bash "$ENGINE" --topics-dir "$TD" --params "$PARAMS" --platform mac \
    --selections "$TMP/sel.dep" 2>&1)"
assert "repeat uninstall: reports zero changed items" "yes" "$(echo "$out" | grep -q 't2/dependent: uninstalled (0 item(s) on mac)' && echo yes || echo no)"
assert "repeat uninstall: no false one-item removal" "no" "$(echo "$out" | grep -q 't2/dependent: uninstalled (1 item(s) on mac)' && echo yes || echo no)"
assert "repeat uninstall: reports zero changed bundles" "yes" "$(echo "$out" | grep -q 'uninstall-engine: removed 0 bundle(s) on mac' && echo yes || echo no)"
out="$(ENGTEST_OUT="$OUT" MESH_INSTALL_STATE_DIR="$ST" \
    bash "$ENGINE" --topics-dir "$TD" --params "$PARAMS" --platform mac \
    --selections "$TMP/sel.dep" --dry-run 2>&1)"
assert "dry-run without marker: reports zero changed items" "yes" "$(echo "$out" | grep -q 't2/dependent: uninstalled (0 item(s) on mac)' && echo yes || echo no)"
assert "dry-run without marker: no false one-item removal" "no" "$(echo "$out" | grep -q 't2/dependent: uninstalled (1 item(s) on mac)' && echo yes || echo no)"
assert "dry-run without marker: reports zero changed bundles" "yes" "$(echo "$out" | grep -q 'uninstall-engine: removed 0 bundle(s) on mac' && echo yes || echo no)"

# ── Test 8: destructive purge needs an explicit two-flag acknowledgement ──
# The normal uninstaller is data-safe. A caller must not be able to turn on
# purge with one accidental flag; both --purge-data and --confirm-purge-data
# are required, and only that pair exposes MESH_PURGE_DATA to custom owners.
mkdir -p "$TD/t4"
cat > "$TD/t4/manifest.yaml" <<'YAML'
topic:
  label: "T4"
  order: 40
bundles:
  - name: purgeable
    label: "Purgeable"
    desc: "custom owner with managed data"
    items:
      - name: owner
        type: custom
        script: ./owner.sh
YAML
cat > "$TD/t4/owner.sh" <<'SH'
check() { [[ -f "${ENGTEST_OUT:?}/purge-data" ]]; }
install() { : > "${ENGTEST_OUT:?}/purge-data"; }
verify() { check; }
uninstall() {
    [[ "${MESH_PURGE_DATA:-0}" == "1" ]] || return 1
    rm -f "${ENGTEST_OUT:?}/purge-data"
}
SH
chmod +x "$TD/t4/owner.sh"
printf 't4/purgeable\n' > "$TMP/sel.t4"

rm -rf "$ST" "$OUT"; mkdir -p "$ST" "$OUT"
ENGTEST_OUT="$OUT" MESH_INSTALL_STATE_DIR="$ST" \
    bash "$WS/scripts/lib/install-engine.sh" --topics-dir "$TD" --params "$PARAMS" \
    --platform mac --bundle t4/purgeable >/dev/null 2>&1
out="$(ENGTEST_OUT="$OUT" MESH_INSTALL_STATE_DIR="$ST" \
    bash "$ENGINE" --topics-dir "$TD" --params "$PARAMS" --platform mac \
    --selections "$TMP/sel.t4" --purge-data 2>&1)"
rc=$?
assert "purge without confirmation: exits 64" "64" "$rc"
assert "purge without confirmation: reports the missing acknowledgement" "yes" "$(echo "$out" | grep -q 'requires --confirm-purge-data' && echo yes || echo no)"
assert "purge without confirmation: data survives" "yes" "$(test -f "$OUT/purge-data" && echo yes || echo no)"
assert "purge without confirmation: marker survives" "yes" "$(test -f "$ST/t4__owner.env" && echo yes || echo no)"

out="$(ENGTEST_OUT="$OUT" MESH_INSTALL_STATE_DIR="$ST" \
    bash "$ENGINE" --topics-dir "$TD" --params "$PARAMS" --platform mac \
    --selections "$TMP/sel.t4" --purge-data --confirm-purge-data 2>&1)"
rc=$?
assert "confirmed purge: exits 0" "0" "$rc"
assert "confirmed purge: custom owner receives purge authority" "no" "$(test -f "$OUT/purge-data" && echo yes || echo no)"
assert "confirmed purge: marker is removed after real purge" "no" "$(test -f "$ST/t4__owner.env" && echo yes || echo no)"

echo ""
echo "uninstall-engine.test: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
