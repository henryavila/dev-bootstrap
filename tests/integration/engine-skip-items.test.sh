#!/usr/bin/env bash
# tests/integration/engine-skip-items.test.sh
#
# MESH_SKIP_ITEMS — a space-separated list of item NAMES the engine drops in
# every mode, finer-grained than the topic-level SKIP_TOPICS (which filters the
# selection by `topic/`). The CI smoke test uses it to skip externally-CDN-bound
# items (rust-bins-wsl pulls dust/xh/procs release tarballs) so a GitHub-release
# stall can't hang/red the pipeline, while the rest of the bundle still installs.
#
# Hermetic: a synthetic topic of two `custom` items whose install() drops a
# sentinel, so "did this item install?" = "does its sentinel exist?". Covers:
#   - a listed item is skipped (no install, logged); a non-listed sibling installs
#   - empty/unset MESH_SKIP_ITEMS = no item skipped (no regression)
#   - matching is whole-word: a substring of an item name does NOT skip it
#   - multiple names in the list are all honored
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
ENGINE="$WS/scripts/lib/install-engine.sh"

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
      - name: keep
        type: custom
        script: ./keep.sh
      - name: drop
        type: custom
        script: ./drop.sh
YAML

# check() fails (not installed) → install() runs and drops a sentinel; verify()
# passes so the engine records the marker and exits 0.
for n in keep drop; do
  cat > "$TOPICS/demo/$n.sh" <<SH
check()   { return 1; }
install() { : > "$SENT/$n-INSTALLED"; }
verify()  { return 0; }
SH
done

export MESH_INSTALL_STATE_DIR="$STATE"
installed() { [[ -f "$SENT/$1-INSTALLED" ]]; }
clean()     { rm -f "$SENT"/* "$STATE"/* 2>/dev/null; }
engine()    { bash "$ENGINE" --topics-dir "$TOPICS" --platform mac --bundle demo/b > "$ROOT/log" 2>&1; }

# ── 1. a listed item is skipped; its sibling still installs ──
clean
( export MESH_SKIP_ITEMS="drop"; engine ); rc=$?
[[ "$rc" -eq 0 ]]  && ok "install pass exits 0 with MESH_SKIP_ITEMS set"           || bad "install rc=$rc"
installed keep     && ok "non-listed item installs normally"                       || bad "keep item did not install"
! installed drop   && ok "listed item is skipped (not installed)"                  || bad "drop item installed despite MESH_SKIP_ITEMS"
grep -q "b/drop: skip (MESH_SKIP_ITEMS)" "$ROOT/log" \
                   && ok "skip is logged with the MESH_SKIP_ITEMS reason"          || bad "skip reason not logged"

# ── 2. empty/unset = nothing skipped (no regression) ──
clean
( unset MESH_SKIP_ITEMS; engine ); rc=$?
[[ "$rc" -eq 0 ]]  && ok "install pass exits 0 with MESH_SKIP_ITEMS unset"         || bad "unset run rc=$rc"
installed keep && installed drop \
                   && ok "unset MESH_SKIP_ITEMS installs every item (no regression)" || bad "an item was skipped without MESH_SKIP_ITEMS"

# ── 3. matching is whole-word: a substring must NOT skip ──
clean
( export MESH_SKIP_ITEMS="dro"; engine ) >/dev/null 2>&1
installed drop     && ok "a substring ('dro') does NOT skip item 'drop'"           || bad "substring wrongly skipped a longer item name"

# ── 4. multiple names in the list are all honored ──
clean
( export MESH_SKIP_ITEMS="keep drop"; engine ) >/dev/null 2>&1
! installed keep && ! installed drop \
                   && ok "multiple listed names are all skipped"                   || bad "a listed name was not skipped in a multi-name list"

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
