#!/usr/bin/env bash
# tests/integration/engine-adopt.test.sh
#
# Regression suite for the read-only marker-backfill mode `engine --adopt`
# (scanner-marker-coherence handoff, Option A; uninstall-wiring T-ADOPT). The
# v2 menu scanner reads installed-state from per-item markers only; a machine
# provisioned by the v1 system has the tools but zero v2 markers, so every
# bundle scans `missing` (false negative). `--adopt` reconciles that drift-in
# state read-only: for each marker-ABSENT item whose strong probe (verify >
# manifest check > driver check) passes, it writes the install marker WITHOUT
# running install/deploy/sudo. Symmetric with --repair (which acts on
# marker-PRESENT items), inverted target.
#
# Uses a synthetic temp topic of custom items (no brew/network) so it runs on
# any platform. Covers:
#   - --adopt is mutually exclusive with --update and with --repair (rc 64)
#   - present (probe ok) + NO marker  → marker written (adopted)
#   - absent  (probe fails) + NO marker → NO marker written
#   - adopt NEVER runs install() (read-only) — no install sentinel for any item
#   - an item that already has a marker is left alone (no-op)
#   - idempotent items (no install-state to adopt) are skipped → no marker
#   - an unprobeable custom item (neither check() nor verify()) is NOT adopted
#   - adopt is idempotent + safe to re-run (rc 0, markers stable, no installs)
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

cat > "$TOPICS/demo/manifest.yaml" <<'YAML'
topic:
  label: "Demo"
  order: 10
bundles:
  - name: b
    items:
      - name: present
        type: custom
        script: ./present.sh
      - name: absent
        type: custom
        script: ./absent.sh
      - name: premarked
        type: custom
        script: ./premarked.sh
      - name: noprobe
        type: custom
        script: ./noprobe.sh
      - name: idem
        type: custom
        script: ./idem.sh
        idempotent: true
YAML

# Each install() drops a sentinel so the test can prove adopt NEVER installs.
# check-only scripts (no verify()) match the real-world majority and exercise
# custom_verify's verify→check fallback.
cat > "$TOPICS/demo/present.sh" <<SH
check()   { return 0; }
install() { : > "$SENT/present-INSTALL-RAN"; }
SH
cat > "$TOPICS/demo/absent.sh" <<SH
check()   { return 1; }
install() { : > "$SENT/absent-INSTALL-RAN"; }
SH
cat > "$TOPICS/demo/premarked.sh" <<SH
check()   { return 0; }
install() { : > "$SENT/premarked-INSTALL-RAN"; }
SH
cat > "$TOPICS/demo/noprobe.sh" <<SH
install() { : > "$SENT/noprobe-INSTALL-RAN"; }
SH
cat > "$TOPICS/demo/idem.sh" <<SH
check()   { return 1; }
install() { : > "$SENT/idem-INSTALL-RAN"; }
SH

export MESH_INSTALL_STATE_DIR="$STATE"
seed_marker()   { printf 'MESH_ITEM_NAME="%s"\n' "$1" > "$STATE/demo__$1.env"; }
marker_exists() { [[ -f "$STATE/demo__$1.env" ]]; }
any_install_ran() { ls "$SENT"/*-INSTALL-RAN >/dev/null 2>&1; }
engine() { bash "$ENGINE" --topics-dir "$TOPICS" --platform mac "$@" > "$ROOT/log" 2>&1; }

# ── 1. mutual exclusion ──
engine --bundle demo/b --adopt --update; rc=$?
[[ "$rc" -eq 64 ]] && ok "--adopt --update rejected (rc 64)" || bad "--adopt --update not rejected (rc=$rc)"
engine --bundle demo/b --adopt --repair; rc=$?
[[ "$rc" -eq 64 ]] && ok "--adopt --repair rejected (rc 64)" || bad "--adopt --repair not rejected (rc=$rc)"

# ── 2. adopt sweep: present adopted, absent skipped, premarked untouched ──
rm -f "$STATE"/*.env "$SENT"/* 2>/dev/null
seed_marker premarked                 # already known to mesh — must stay a no-op
engine --bundle demo/b --adopt; rc=$?
[[ "$rc" -eq 0 ]]        && ok "adopt sweep exits 0 (read-only, best-effort)" || bad "adopt did not exit 0 (rc=$rc)"
marker_exists present   && ok "present item (probe ok, no marker) → marker written" || bad "present item not adopted"
! marker_exists absent  && ok "absent item (probe fails) → no marker written"        || bad "absent item wrongly adopted"
marker_exists premarked && ok "pre-marked item left alone (marker preserved)"        || bad "pre-marked item lost its marker"
! marker_exists noprobe && ok "unprobeable custom item → not adopted (no marker)"    || bad "unprobeable item wrongly adopted"
! marker_exists idem    && ok "idempotent item skipped (no install-state to adopt)"  || bad "idempotent item wrongly adopted"
! any_install_ran       && ok "adopt NEVER ran install() for any item (read-only)"   || bad "adopt ran install() (not read-only)"
grep -q "present: adopted" "$ROOT/log" && ok "adopt logged the backfill for present" || bad "adopt did not log present backfill"

# ── 3. idempotent re-run ──
engine --bundle demo/b --adopt; rc=$?
[[ "$rc" -eq 0 ]]      && ok "re-run exits 0 (idempotent)"                  || bad "re-run did not exit 0 (rc=$rc)"
marker_exists present  && ok "re-run keeps the present marker"             || bad "re-run dropped the present marker"
! marker_exists absent && ok "re-run still leaves the absent item unmarked" || bad "re-run wrongly adopted absent"
! any_install_ran      && ok "re-run still never installs"                 || bad "re-run ran install()"

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
