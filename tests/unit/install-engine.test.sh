#!/usr/bin/env bash
# Unit tests for scripts/lib/install-engine.sh (manifest v2 bundle engine).
# Covers: requires_bundles closure + topological order, platform gating,
# when: (option.X + named condition + unknown→exit 71), options→env export,
# idempotent items, install-marker write/skip on re-run, the deploy driver,
# and cycle detection (exit 70).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
ENGINE="$WS/scripts/lib/install-engine.sh"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected: [$expected], got: [$actual])" >&2; fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TD="$TMP/topics"; ST="$TMP/state/installed"; OUT="$TMP/out"; HOMEDIR="$TMP/home"
PARAMS="$TMP/params.env"
mkdir -p "$TD/t1" "$TD/t2" "$ST" "$OUT" "$HOMEDIR"

# ── topic t1 (order 10): bundle base ──
cat > "$TD/t1/manifest.yaml" <<'YAML'
topic:
  label: "T1"
  order: 10
bundles:
  - name: base
    label: "Base"
    desc: "no deps"
    items:
      - name: mk-base
        type: custom
        script: ./mk-base.sh
      - name: idem
        type: custom
        script: ./idem.sh
        idempotent: true
YAML

# ── topic t2 (order 20): dependent + opt bundles ──
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
    items:
      - name: mk-dep
        type: custom
        script: ./mk-dep.sh
      - name: wsl-only
        type: custom
        script: ./wsl-only.sh
        platforms: [wsl]
  - name: opt
    label: "Opt"
    desc: "option-gated + named-cond + deploy"
    options:
      - name: flag
        type: toggle
        label: "Flag"
        env: T2_FLAG
        default: false
    items:
      - name: gated
        type: custom
        script: ./gated.sh
        when: option.flag
      - name: corp
        type: custom
        script: ./corp.sh
        when: wsl_corporate
      - name: frag
        type: deploy
        spec: ./templates/opt
        idempotent: true
YAML

# custom scripts: append name to runlog on install (ordering probe), touch .done
_mk() {  # $1 = topic dir, $2 = name
    cat > "$1/$2.sh" <<SH
TAG="$2"; OUT="\${ENGTEST_OUT:?}"
check()   { [ -f "\$OUT/\$TAG.done" ]; }
install() { echo "\$TAG" >> "\$OUT/runlog.txt"; : > "\$OUT/\$TAG.done"; }
verify()  { check; }
SH
    chmod +x "$1/$2.sh"
}
_mk "$TD/t1" mk-base
_mk "$TD/t1" idem
_mk "$TD/t2" mk-dep
_mk "$TD/t2" wsl-only
_mk "$TD/t2" corp
# gated.sh records the option env value to prove options→env export
cat > "$TD/t2/gated.sh" <<'SH'
TAG=gated; OUT="${ENGTEST_OUT:?}"
check()   { [ -f "$OUT/$TAG.done" ]; }
install() { echo "gated:T2_FLAG=${T2_FLAG:-unset}" >> "$OUT/runlog.txt"; : > "$OUT/$TAG.done"; }
verify()  { check; }
SH
chmod +x "$TD/t2/gated.sh"
# deploy template (auto-mapped bashrc.d fragment)
mkdir -p "$TD/t2/templates/opt"
echo '# t2 opt fragment' > "$TD/t2/templates/opt/bashrc.d-77-t2opt.sh"

run_engine() {  # extra args after the standard ones
    ENGTEST_OUT="$OUT" HOME="$HOMEDIR" MESH_INSTALL_STATE_DIR="$ST" \
        bash "$ENGINE" --topics-dir "$TD" --params "$PARAMS" --platform mac "$@" 2>&1
}
reset_state() { rm -rf "$ST" "$OUT" "$HOMEDIR"; mkdir -p "$ST" "$OUT" "$HOMEDIR"; }

# ── Test 1: requires_bundles closure + topo order (deps first) ──
: > "$PARAMS"
printf 't2/dependent\n' > "$TMP/sel.list"
reset_state
out="$(run_engine --selections "$TMP/sel.list" --non-interactive)"
assert "closure: auto-selects t1/base" "yes" "$(echo "$out" | grep -q 'auto-selecting t1/base' && echo yes || echo no)"
assert "topo: base bundle (both items) runs before dep" "mk-base
idem
mk-dep" "$(cat "$OUT/runlog.txt")"
assert "platform: wsl-only skipped on mac" "yes" "$(echo "$out" | grep -q 'wsl-only: skip (platforms' && echo yes || echo no)"

# ── Test 2: marker written on success ──
assert "marker: t1__mk-base.env written" "yes" "$(test -f "$ST/t1__mk-base.env" && echo yes || echo no)"

# ── Test 3: idempotent always runs; non-idempotent skips via check on re-run ──
out="$(run_engine --selections "$TMP/sel.list" --non-interactive)"
assert "re-run: mk-base skipped (already present)" "yes" "$(echo "$out" | grep -q 'mk-base: already present' && echo yes || echo no)"
assert "re-run: idem runs again (idempotent)" "yes" "$(echo "$out" | grep -q 'idem: running (idempotent)' && echo yes || echo no)"

# ── Test 4: when: option.X — off by default (non-interactive), on when set ──
reset_state
printf 't2/opt\n' > "$TMP/sel.opt"
out="$(run_engine --selections "$TMP/sel.opt" --non-interactive)"
assert "when option off: gated skipped" "yes" "$(echo "$out" | grep -q 'gated: skip (when: option.flag is off)' && echo yes || echo no)"
reset_state
printf 'T2_FLAG=1\n' > "$PARAMS"
out="$(run_engine --selections "$TMP/sel.opt")"
assert "when option on (params): gated runs" "yes" "$(grep -q 'gated:T2_FLAG=1' "$OUT/runlog.txt" && echo yes || echo no)"
: > "$PARAMS"

# ── Test 5: when: named condition (wsl_corporate via test hooks) ──
reset_state
out="$(MESH_COND_OS=wsl MESH_WSL_CORPORATE=1 run_engine --selections "$TMP/sel.opt" --non-interactive)"
assert "when named true: corp runs" "yes" "$(test -f "$OUT/corp.done" && echo yes || echo no)"
reset_state
out="$(run_engine --selections "$TMP/sel.opt" --non-interactive)"
assert "when named false: corp skipped" "yes" "$(echo "$out" | grep -q 'corp: skip (when: wsl_corporate is false)' && echo yes || echo no)"

# ── Test 6: deploy driver renders the fragment into HOME ──
assert "deploy: bashrc.d fragment landed" "yes" "$(test -f "$HOMEDIR/.bashrc.d/77-t2opt.sh" && echo yes || echo no)"

# ── Test 7: unknown when: condition → exit 71 ──
mkdir -p "$TD/tbad"
cat > "$TD/tbad/manifest.yaml" <<'YAML'
topic:
  label: "Bad"
  order: 30
bundles:
  - name: b
    label: "B"
    desc: "bad when"
    items:
      - name: x
        type: custom
        script: ./mk-base.sh
        when: no_such_condition
YAML
cp "$TD/t1/mk-base.sh" "$TD/tbad/mk-base.sh"
reset_state
printf 'tbad/b\n' > "$TMP/sel.bad"
ENGTEST_OUT="$OUT" HOME="$HOMEDIR" MESH_INSTALL_STATE_DIR="$ST" \
    bash "$ENGINE" --topics-dir "$TD" --params "$PARAMS" --platform mac \
    --selections "$TMP/sel.bad" --non-interactive >/dev/null 2>&1
assert "unknown when: exit 71" "71" "$?"

# ── Test 8: requires_bundles cycle → exit 70 ──
mkdir -p "$TD/tcyc"
cat > "$TD/tcyc/manifest.yaml" <<'YAML'
topic:
  label: "Cyc"
  order: 40
bundles:
  - name: x
    label: "X"
    desc: "cycle x"
    requires_bundles:
      - tcyc/y
    items:
      - name: i
        type: custom
        script: ./mk-base.sh
  - name: y
    label: "Y"
    desc: "cycle y"
    requires_bundles:
      - tcyc/x
    items:
      - name: j
        type: custom
        script: ./mk-base.sh
YAML
cp "$TD/t1/mk-base.sh" "$TD/tcyc/mk-base.sh"
printf 'tcyc/x\n' > "$TMP/sel.cyc"
ENGTEST_OUT="$OUT" HOME="$HOMEDIR" MESH_INSTALL_STATE_DIR="$ST" \
    bash "$ENGINE" --topics-dir "$TD" --platform mac \
    --selections "$TMP/sel.cyc" --non-interactive >/dev/null 2>&1
assert "requires_bundles cycle: exit 70" "70" "$?"

echo ""
echo "install-engine.test: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
