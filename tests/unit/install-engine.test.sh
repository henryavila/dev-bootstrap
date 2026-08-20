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

reset_state
closure_out="$(
    ENGTEST_OUT="$OUT" HOME="$HOMEDIR" MESH_INSTALL_STATE_DIR="$ST" \
        bash "$ENGINE" --topics-dir "$TD" --params "$PARAMS" --platform mac \
        --selections "$TMP/sel.list" --non-interactive --print-closure 2>"$TMP/closure.err"
)"
assert "print-closure: stdout is dependency-closed topo order" "t1/base
t2/dependent" "$closure_out"
assert "print-closure: does not install items" "no" "$(test -f "$OUT/runlog.txt" && echo yes || echo no)"
out="$(run_engine --selections "$TMP/sel.list" --non-interactive)"

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

# ── Test 9: soft_fail item failure continues; hard-fail still aborts ──
mkdir -p "$TD/tsoft"
cat > "$TD/tsoft/manifest.yaml" <<'YAML'
topic:
  label: "Soft"
  order: 50
bundles:
  - name: tools
    label: "Tools"
    desc: "soft then hard"
    items:
      - name: flaky-cdn
        type: custom
        script: ./flaky-cdn.sh
        soft_fail: true
      - name: after-soft
        type: custom
        script: ./after-soft.sh
      - name: hard-fail
        type: custom
        script: ./hard-fail.sh
      - name: after-hard
        type: custom
        script: ./after-hard.sh
YAML
cat > "$TD/tsoft/flaky-cdn.sh" <<'SH'
check()   { return 1; }
install() { echo "flaky-cdn" >> "${ENGTEST_OUT:?}/runlog.txt"; return 1; }
verify()  { return 1; }
SH
cat > "$TD/tsoft/after-soft.sh" <<'SH'
check()   { [ -f "${ENGTEST_OUT:?}/after-soft.done" ]; }
install() { echo "after-soft" >> "${ENGTEST_OUT:?}/runlog.txt"; : > "${ENGTEST_OUT:?}/after-soft.done"; }
verify()  { check; }
SH
cat > "$TD/tsoft/hard-fail.sh" <<'SH'
check()   { return 1; }
install() { echo "hard-fail" >> "${ENGTEST_OUT:?}/runlog.txt"; return 1; }
verify()  { return 1; }
SH
cat > "$TD/tsoft/after-hard.sh" <<'SH'
check()   { [ -f "${ENGTEST_OUT:?}/after-hard.done" ]; }
install() { echo "after-hard" >> "${ENGTEST_OUT:?}/runlog.txt"; : > "${ENGTEST_OUT:?}/after-hard.done"; }
verify()  { check; }
SH
chmod +x "$TD/tsoft/"*.sh
reset_state
FOLLOWUP="$TMP/followup.soft"
: > "$FOLLOWUP"
printf 'tsoft/tools\n' > "$TMP/sel.soft"
ENGTEST_OUT="$OUT" HOME="$HOMEDIR" MESH_INSTALL_STATE_DIR="$ST" MESH_FOLLOWUP_FILE="$FOLLOWUP" \
    bash "$ENGINE" --topics-dir "$TD" --params "$PARAMS" --platform mac \
    --selections "$TMP/sel.soft" --non-interactive >"$TMP/soft.out" 2>&1
soft_rc=$?
soft_log="$(cat "$OUT/runlog.txt" 2>/dev/null || true)"
assert "soft_fail: after-soft still ran" "yes" "$(printf '%s\n' "$soft_log" | grep -qx 'after-soft' && echo yes || echo no)"
assert "soft_fail: hard-fail was attempted" "yes" "$(printf '%s\n' "$soft_log" | grep -qx 'hard-fail' && echo yes || echo no)"
assert "soft_fail: after-hard did NOT run (hard abort)" "no" "$(printf '%s\n' "$soft_log" | grep -qx 'after-hard' && echo yes || echo no)"
assert "soft_fail: run exits non-zero from hard-fail neighbour" "yes" "$([[ "$soft_rc" -ne 0 ]] && echo yes || echo no)"
assert "soft_fail: no install marker for flaky-cdn" "no" "$(test -f "$ST/tsoft__flaky-cdn.env" && echo yes || echo no)"
assert "soft_fail: followup recorded" "yes" "$(grep -q 'flaky-cdn' "$FOLLOWUP" && echo yes || echo no)"
assert "soft_fail: warn in engine output" "yes" "$(grep -qiE 'soft.fail|continuing' "$TMP/soft.out" && echo yes || echo no)"

# ── Test 10: soft_fail wall-clock timeout continues ──
mkdir -p "$TD/thang"
cat > "$TD/thang/manifest.yaml" <<'YAML'
topic:
  label: "Hang"
  order: 60
bundles:
  - name: tools
    label: "Tools"
    desc: "hang then continue"
    items:
      - name: hung-cdn
        type: custom
        script: ./hung-cdn.sh
        soft_fail: true
      - name: after-hang
        type: custom
        script: ./after-hang.sh
YAML
cat > "$TD/thang/hung-cdn.sh" <<'SH'
check()   { return 1; }
install() {
    echo "hung-cdn" >> "${ENGTEST_OUT:?}/runlog.txt"
    # Background grandchild that outlives a top-PID-only kill — must die with
    # process-group kill (mirrors hung curl children under custom_install).
    (
        sleep 3
        echo orphaned >> "${ENGTEST_OUT:?}/orphan.txt"
    ) &
    sleep 30
}
verify()  { return 1; }
SH
cat > "$TD/thang/after-hang.sh" <<'SH'
check()   { [ -f "${ENGTEST_OUT:?}/after-hang.done" ]; }
install() { echo "after-hang" >> "${ENGTEST_OUT:?}/runlog.txt"; : > "${ENGTEST_OUT:?}/after-hang.done"; }
verify()  { check; }
SH
chmod +x "$TD/thang/"*.sh
reset_state
FOLLOWUP="$TMP/followup.hang"
: > "$FOLLOWUP"
printf 'thang/tools\n' > "$TMP/sel.hang"
ENGTEST_OUT="$OUT" HOME="$HOMEDIR" MESH_INSTALL_STATE_DIR="$ST" \
    MESH_FOLLOWUP_FILE="$FOLLOWUP" MESH_SOFT_FAIL_TIMEOUT=1 \
    bash "$ENGINE" --topics-dir "$TD" --params "$PARAMS" --platform mac \
    --selections "$TMP/sel.hang" --non-interactive >"$TMP/hang.out" 2>&1
hang_rc=$?
hang_log="$(cat "$OUT/runlog.txt" 2>/dev/null || true)"
# Give a would-be orphan time to write if the kill leaked children.
sleep 4
assert "soft_fail timeout: run exits 0" "0" "$hang_rc"
assert "soft_fail timeout: after-hang ran" "yes" "$(printf '%s\n' "$hang_log" | grep -qx 'after-hang' && echo yes || echo no)"
assert "soft_fail timeout: followup recorded" "yes" "$(grep -q 'hung-cdn' "$FOLLOWUP" && echo yes || echo no)"
assert "soft_fail timeout: process-group kill (no orphan)" "no" "$(test -f "$OUT/orphan.txt" && echo yes || echo no)"

echo ""
echo "install-engine.test: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
