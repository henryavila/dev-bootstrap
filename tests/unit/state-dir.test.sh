#!/usr/bin/env bash
# Unit tests for lib/state-dir.sh — canonical state dir + one-shot legacy
# migration (audit T-004; decision D2 = move-and-remove, canonical wins).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
. "$WS/scripts/lib/state-dir.sh"

passed=0; failed=0
ok() { passed=$((passed+1)); echo "  ✓ $1"; }
no() { failed=$((failed+1)); echo "  ✗ $1" >&2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Test 1: mesh_state_dir honors XDG_STATE_HOME
( export HOME="$TMP/h1" XDG_STATE_HOME="$TMP/h1/xdgstate"; unset MESH_STATE_DIR
  [[ "$(mesh_state_dir)" == "$TMP/h1/xdgstate/mesh" ]] ) \
  && ok "mesh_state_dir uses \$XDG_STATE_HOME/mesh" || no "mesh_state_dir XDG"

# Test 2: mesh_state_dir falls back to ~/.local/state/mesh, MESH_STATE_DIR overrides
( export HOME="$TMP/h2"; unset XDG_STATE_HOME MESH_STATE_DIR
  [[ "$(mesh_state_dir)" == "$TMP/h2/.local/state/mesh" ]] ) \
  && ok "mesh_state_dir falls back to ~/.local/state/mesh" || no "mesh_state_dir fallback"
( export HOME="$TMP/h2" MESH_STATE_DIR="$TMP/override"
  [[ "$(mesh_state_dir)" == "$TMP/override" ]] ) \
  && ok "MESH_STATE_DIR overrides" || no "MESH_STATE_DIR override"

# Test 3: migration moves both legacy dirs → mesh and removes them
H="$TMP/h3"; export HOME="$H"; unset XDG_STATE_HOME MESH_STATE_DIR
mkdir -p "$H/.local/state/mesh-workstation/snapshots/x" "$H/.local/state/dev-bootstrap"
echo "tok" > "$H/.local/state/mesh-workstation/secrets.env"
echo "sha" > "$H/.local/state/mesh-workstation/last-applied-foo"
echo "db"  > "$H/.local/state/dev-bootstrap/config.env"
mesh_migrate_legacy_state 2>/dev/null
canon="$H/.local/state/mesh"
if [[ "$(cat "$canon/secrets.env" 2>/dev/null)" == "tok" \
   && "$(cat "$canon/last-applied-foo" 2>/dev/null)" == "sha" \
   && -d "$canon/snapshots/x" \
   && "$(cat "$canon/config.env" 2>/dev/null)" == "db" ]]; then
  ok "migration moves files + subdirs from both legacy dirs into mesh"
else no "migration content"; fi
if [[ ! -d "$H/.local/state/mesh-workstation" && ! -d "$H/.local/state/dev-bootstrap" ]]; then
  ok "legacy dirs removed after migration (move-and-remove)"
else no "legacy dirs not removed"; fi

# Test 4: canonical wins on conflict (existing mesh file not clobbered, legacy dropped)
H="$TMP/h4"; export HOME="$H"; unset XDG_STATE_HOME MESH_STATE_DIR
mkdir -p "$H/.local/state/mesh" "$H/.local/state/mesh-workstation"
echo "current" > "$H/.local/state/mesh/secrets.env"
echo "stale"   > "$H/.local/state/mesh-workstation/secrets.env"
mesh_migrate_legacy_state 2>/dev/null
if [[ "$(cat "$H/.local/state/mesh/secrets.env")" == "current" \
   && ! -d "$H/.local/state/mesh-workstation" ]]; then
  ok "canonical wins on conflict; stale legacy copy dropped + dir removed"
else no "conflict handling"; fi

# Test 5: idempotent / no legacy → no-op, no error
H="$TMP/h5"; export HOME="$H"; unset XDG_STATE_HOME MESH_STATE_DIR
mkdir -p "$H/.local/state/mesh"
mesh_migrate_legacy_state 2>/dev/null && ok "no legacy dir → clean no-op" || no "no-op errored"

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
