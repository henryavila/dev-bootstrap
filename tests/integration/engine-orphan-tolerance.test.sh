#!/usr/bin/env bash
# tests/integration/engine-orphan-tolerance.test.sh
#
# Regression suite for engine orphan-tolerance (initiative autoupdate-robustness,
# phase P1 / F-A). A stale selections.list can name a bundle that was
# renamed/split/removed (e.g. ai/agent-tools after the per-tool split). Before
# this fix, install-engine.sh:384 / uninstall-engine.sh:185 did `exit 64` on the
# FIRST unresolvable selection — one orphan poisoned the whole run, including the
# version-aware --update pass for the items the user actually wanted upgraded.
#
# Now: unresolvable selections are warned + skipped; exit 64 only when EVERY
# selection is an orphan; a present-but-unparseable manifest stays exit 65.
# Covers install + uninstall engines, the requires_bundles closure, and the
# --update regression (orphan must NOT block autoupdate of valid bundles).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
ENGINE="$WS/scripts/lib/install-engine.sh"
UNINSTALL="$WS/scripts/lib/uninstall-engine.sh"

passed=0; failed=0
ok()  { passed=$((passed+1)); echo "  ✓ $1"; }
bad() { failed=$((failed+1)); echo "  ✗ $1" >&2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
export TOPICS="$ROOT/topics" STATE="$ROOT/state" SENT="$ROOT/sentinels"
mkdir -p "$TOPICS/demo" "$STATE" "$SENT"

cat > "$TOPICS/demo/manifest.yaml" <<'YAML'
topic:
  label: "Demo"
  order: 10
bundles:
  - name: b
    items:
      - name: bi
        type: custom
        script: ./bi.sh
        autoupdate: true
  - name: c
    requires_bundles:
      - demo/b
    items:
      - name: ci
        type: custom
        script: ./ci.sh
  - name: d
    items:
      - name: di
        type: custom
        script: ./di.sh
YAML

# bi: "installed" (check=0) + autoupdate → only the --update pass touches it.
cat > "$TOPICS/demo/bi.sh" <<SH
check()  { return 0; }
install(){ return 0; }
update() { : > "$SENT/bi-UPDATE-RAN"; }
uninstall() { : > "$SENT/bi-UNINSTALL-RAN"; }
SH
# ci: not installed (check=1) → install() runs and drops a sentinel. verify=0
# so post-install verification passes and the engine returns rc 0 (not 67).
cat > "$TOPICS/demo/ci.sh" <<SH
check()  { return 1; }
install(){ : > "$SENT/ci-INSTALL-RAN"; }
verify() { return 0; }
uninstall() { : > "$SENT/ci-UNINSTALL-RAN"; return 0; }
SH
# di: not installed (check=1) → install() runs and drops a sentinel. verify=0.
cat > "$TOPICS/demo/di.sh" <<SH
check()  { return 1; }
install(){ : > "$SENT/di-INSTALL-RAN"; }
verify() { return 0; }
uninstall() { : > "$SENT/di-UNINSTALL-RAN"; return 0; }
SH

export MESH_INSTALL_STATE_DIR="$STATE"
ran()    { [[ -f "$SENT/$1" ]]; }
clean()  { rm -f "$SENT"/* "$STATE"/* 2>/dev/null; }
writes() { printf '%s\n' "$@" > "$ROOT/sel"; }

# install engine over a selections file; --update switches to the version pass.
eng_install() { bash "$ENGINE"    --topics-dir "$TOPICS" --platform mac --selections "$ROOT/sel" "$@" > "$ROOT/log" 2>&1; }
eng_update()  { bash "$ENGINE"    --topics-dir "$TOPICS" --platform mac --selections "$ROOT/sel" --update "$@" > "$ROOT/log" 2>&1; }
eng_uninst()  { bash "$UNINSTALL" --topics-dir "$TOPICS" --platform mac --selections "$ROOT/sel" "$@" > "$ROOT/log" 2>&1; }

# ── 1. install: orphan skipped, valid bundles proceed, rc 0 ───────────────────
clean
writes 'demo/ghost' 'demo/b' 'demo/d'
( unset MESH_UPDATE_AGENT_CLIS MESH_UPDATE_CLI_TOOLS MESH_UPDATE_RUNTIMES_DBS \
        MESH_AUTOUPDATE_FILE MESH_AUTOUPDATE_ALIAS; eng_install ); rc=$?
[[ "$rc" -eq 0 ]]   && ok "install: rc 0 with one orphan + valid bundles"      || bad "install: rc=$rc (expected 0)"
ran di-INSTALL-RAN  && ok "install: valid bundle d processed (install ran)"     || bad "install: bundle d not processed"
! ran ci-INSTALL-RAN && ok "install: unselected bundle c left alone"            || bad "install: c wrongly processed"
grep -q 'demo/ghost' "$ROOT/log" && grep -qi 'skip' "$ROOT/log" \
                   && ok "install: orphan demo/ghost warned+skipped"            || bad "install: orphan not warned/skipped"

# ── 2. install: ALL selections orphan → exit 64 (no silent no-op) ─────────────
clean
writes 'demo/ghost1' 'demo/ghost2'
eng_install; rc=$?
[[ "$rc" -eq 64 ]]  && ok "install: all-orphan → exit 64 (refuses to no-op)"    || bad "install: all-orphan rc=$rc (expected 64)"

# ── 3. install: requires_bundles closure intact on the filtered set ───────────
clean
writes 'demo/c' 'demo/ghost'
eng_install; rc=$?
[[ "$rc" -eq 0 ]]   && ok "install: closure run rc 0 (c + auto-selected dep b)" || bad "install: closure rc=$rc"
ran ci-INSTALL-RAN  && ok "install: c processed (its dep b auto-selected)"      || bad "install: c not processed despite closure"
grep -qi 'auto-selecting demo/b' "$ROOT/log" \
                   && ok "install: closure auto-selected demo/b (required by c)" || bad "install: dep b not auto-selected"

# ── 4. --update: orphan must NOT block autoupdate of a valid bundle ───────────
# (THE regression: previously the orphan made --update exit 64 before any item.)
clean
writes 'demo/b' 'demo/ghost'
( unset MESH_UPDATE_AGENT_CLIS MESH_UPDATE_CLI_TOOLS MESH_UPDATE_RUNTIMES_DBS \
        MESH_AUTOUPDATE_FILE MESH_AUTOUPDATE_ALIAS; eng_update ); rc=$?
[[ "$rc" -eq 0 ]]   && ok "update: rc 0 with orphan in selections"             || bad "update: rc=$rc (expected 0 — orphan poisoned the pass)"
ran bi-UPDATE-RAN   && ok "update: valid bundle's autoupdate item ran despite orphan" || bad "update: bi did not update"
grep -q 'demo/ghost' "$ROOT/log" && grep -qi 'skip' "$ROOT/log" \
                   && ok "update: orphan demo/ghost warned+skipped"             || bad "update: orphan not warned/skipped"

# ── 5. uninstall mirror: orphan skipped, valid bundle proceeds, rc != 64 ──────
clean
writes 'demo/ghost' 'demo/d'
eng_uninst; rc=$?
[[ "$rc" -ne 64 ]]  && ok "uninstall: rc=$rc (not 64 — orphan tolerated)"      || bad "uninstall: rc=64 (orphan aborted the run)"
grep -q 'demo/ghost' "$ROOT/log" && grep -qi 'skip' "$ROOT/log" \
                   && ok "uninstall: orphan demo/ghost warned+skipped"          || bad "uninstall: orphan not warned/skipped"

# ── 6. uninstall mirror: ALL selections orphan → exit 64 ──────────────────────
clean
writes 'demo/ghost1' 'demo/ghost2'
eng_uninst; rc=$?
[[ "$rc" -eq 64 ]]  && ok "uninstall: all-orphan → exit 64"                    || bad "uninstall: all-orphan rc=$rc (expected 64)"

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
