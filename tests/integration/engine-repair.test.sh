#!/usr/bin/env bash
# tests/integration/engine-repair.test.sh
#
# Regression suite for the verify/operational repair plan (§C engine --repair +
# §7 must-fix). Uses a synthetic temp topic of custom items (no brew/network) so
# it runs on any platform. Covers:
#   - --repair and --update are mutually exclusive (rc 64)
#   - normal keep/skip verifies a check-present item before accepting it; a
#     check=0/verify=1 custom item without repair() is reported unresolved
#   - --repair: healthy item is OK; broken+repair() item is repaired; broken
#     item WITHOUT repair() (custom) is reported unresolved (rc 67)
#   - --repair only touches marker-present items (no-marker probe-fail is skipped)
#   - idempotent items are skipped by the repair sweep
#   - a fully healthy tree exits 0 under --repair
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
ENGINE="$WS/scripts/lib/install-engine.sh"

passed=0; failed=0
ok()  { passed=$((passed+1)); echo "  ✓ $1"; }
bad() { failed=$((failed+1)); echo "  ✗ $1" >&2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
TOPICS="$ROOT/topics"; STATE="$ROOT/state"; SENT="$ROOT/sentinels"
mkdir -p "$TOPICS/demo" "$STATE" "$SENT"

# Two bundles: `b` exercises the repair sweep; `sv` isolates the normal
# check-present/verify-broken path.
cat > "$TOPICS/demo/manifest.yaml" <<'YAML'
topic:
  label: "Demo"
  order: 10
bundles:
  - name: b
    items:
      - name: healthy
        type: custom
        script: ./healthy.sh
      - name: fixable
        type: custom
        script: ./fixable.sh
      - name: unrepairable
        type: custom
        script: ./unrepairable.sh
      - name: nomarker
        type: custom
        script: ./nomarker.sh
      - name: idem
        type: custom
        script: ./idem.sh
        idempotent: true
  - name: sv
    items:
      - name: skipverify
        type: custom
        script: ./skipverify.sh
YAML

cat > "$TOPICS/demo/healthy.sh" <<'SH'
check()  { return 0; }
verify() { check; }
install(){ : ; }
SH
cat > "$TOPICS/demo/fixable.sh" <<SH
S="$SENT/fixable"
check()  { [[ -f "\$S" ]]; }
verify() { check; }
install(){ : ; }
repair() { : > "\$S"; }
SH
cat > "$TOPICS/demo/unrepairable.sh" <<'SH'
check()  { return 1; }
verify() { check; }
install(){ : ; }
SH
cat > "$TOPICS/demo/nomarker.sh" <<SH
check()  { return 1; }
verify() { check; }
install(){ : ; }
repair() { : > "$SENT/nomarker-REPAIR-RAN"; }
SH
cat > "$TOPICS/demo/idem.sh" <<SH
check()  { return 1; }
verify() { return 1; }
install(){ : > "$SENT/idem-INSTALL-RAN"; }
repair() { : > "$SENT/idem-REPAIR-RAN"; }
SH
cat > "$TOPICS/demo/skipverify.sh" <<SH
check()  { return 0; }
verify() { : > "$SENT/skipverify-VERIFY-RAN"; return 1; }
install(){ : ; }
SH

export MESH_INSTALL_STATE_DIR="$STATE"
seed_marker() { printf 'MESH_ITEM_NAME="%s"\n' "$1" > "$STATE/demo__$1.env"; }
engine() { bash "$ENGINE" --topics-dir "$TOPICS" --platform mac "$@" > "$ROOT/log" 2>&1; }

# ── 1. mutual exclusion ──
engine --bundle demo/b --repair --update; rc=$?
[[ "$rc" -eq 64 ]] && ok "--repair --update rejected (rc 64)" || bad "--repair --update not rejected (rc=$rc)"

# ── 2. normal apply verifies before skip (check=0 / verify=1) ──
rm -f "$SENT/skipverify-VERIFY-RAN"
engine --bundle demo/sv; rc=$?
if [[ "$rc" -eq 67 && -f "$SENT/skipverify-VERIFY-RAN" ]] \
    && grep -qi "no safe auto-repair" "$ROOT/log"; then
    ok "normal apply verifies check-present items and reports no-safe-repair"
else
    bad "normal apply did not verify/report check-present broken item (rc=$rc, sentinel=$([[ -f "$SENT/skipverify-VERIFY-RAN" ]] && echo present || echo absent))"
fi

# ── 3. repair sweep: fixable repaired, healthy ok, unrepairable unresolved ──
rm -f "$SENT"/* 2>/dev/null
for n in healthy fixable unrepairable idem; do seed_marker "$n"; done   # nomarker: NO marker
engine --bundle demo/b --repair; rc=$?
[[ "$rc" -eq 67 ]] && ok "repair sweep with an unrepairable item exits 67" || bad "expected rc 67, got $rc"
[[ -f "$SENT/fixable" ]] && ok "fixable item repaired via repair()" || bad "fixable not repaired"
[[ ! -f "$SENT/nomarker-REPAIR-RAN" ]] && ok "no-marker probe-fail item skipped (not repaired)" || bad "no-marker item was repaired (should skip)"
[[ ! -f "$SENT/idem-REPAIR-RAN" && ! -f "$SENT/idem-INSTALL-RAN" ]] && ok "idempotent item skipped by repair sweep" || bad "idempotent item touched by repair sweep"
grep -qi "could not be repaired\|no safe auto-repair" "$ROOT/log" && ok "unrepairable item reported in the summary" || bad "unrepairable item not reported"

# ── 4. healthy tree → rc 0 ──
rm -f "$STATE"/*.env 2>/dev/null
: > "$SENT/fixable"                      # make fixable healthy
for n in healthy fixable; do seed_marker "$n"; done
# Select a bundle that contains only now-healthy items by removing the broken ones.
cat > "$TOPICS/demo/manifest.yaml" <<'YAML'
topic:
  label: "Demo"
  order: 10
bundles:
  - name: b
    items:
      - name: healthy
        type: custom
        script: ./healthy.sh
      - name: fixable
        type: custom
        script: ./fixable.sh
YAML
engine --bundle demo/b --repair; rc=$?
[[ "$rc" -eq 0 ]] && ok "fully healthy tree exits 0 under --repair" || bad "healthy tree did not exit 0 (rc=$rc)"

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
