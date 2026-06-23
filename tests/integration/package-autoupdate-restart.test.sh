#!/usr/bin/env bash
# tests/integration/package-autoupdate-restart.test.sh
#
# Regression suite for T-007 (initiative package-autoupdate): after an item
# self-updates and its binary actually CHANGED, the engine restarts a linked
# managed service so the running daemon picks up the new binary — without a
# manual `brew services restart`. This is the moshi-hook case: the autoupdate
# pass upgrades the formula, but the launchd/brew-services daemon keeps running
# the old binary until it is bounced.
#
# Two declarative pieces:
#   - the package item carries `restart_service: <sibling-item-name>`;
#   - the driver `<type>_update` returns the sentinel rc 10 when it performed a
#     REAL upgrade (vs rc 0 = ran, already latest). The engine, on rc 10, sources
#     the named sibling item's script and calls its restart() verb.
#
# Hermetic: synthetic `custom` items (no brew/launchd/systemd). Each service's
# restart() drops a sentinel, so "did the service get bounced?" = "does its
# sentinel exist?". The one driver-level brew check uses a fake `brew` on PATH.
# Covers:
#   - update reports CHANGED (rc 10) → the linked service restart() runs
#   - update reports NO change (rc 0) → the linked service is NOT bounced
#   - restart_service whose script defines no restart() → graceful logged skip
#   - restart_service naming a non-existent sibling → graceful logged skip
#   - --dry-run never restarts anything (no mutation)
#   - brew_formula_update returns 10 only when `brew outdated` flags the formula
#   - the real moshi service scripts define restart()
#   - yaml-parse emits _RESTART_SERVICE and the ai manifest wires moshi-hook
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
      - name: pkg-changed
        type: custom
        script: ./pkg-changed.sh
        autoupdate: true
        restart_service: svc-a
      - name: pkg-nochange
        type: custom
        script: ./pkg-nochange.sh
        autoupdate: true
        restart_service: svc-b
      - name: pkg-norestartfn
        type: custom
        script: ./pkg-norestartfn.sh
        autoupdate: true
        restart_service: svc-nofn
      - name: pkg-badref
        type: custom
        script: ./pkg-badref.sh
        autoupdate: true
        restart_service: ghost
      - name: svc-a
        type: custom
        script: ./svc-a.sh
      - name: svc-b
        type: custom
        script: ./svc-b.sh
      - name: svc-nofn
        type: custom
        script: ./svc-nofn.sh
YAML

# package items: installed (check()=0). rc 10 = upgraded/changed; rc 0 = latest.
cat > "$TOPICS/demo/pkg-changed.sh"     <<SH
check()  { return 0; }
update() { return 10; }
SH
cat > "$TOPICS/demo/pkg-nochange.sh"    <<SH
check()  { return 0; }
update() { return 0; }
SH
cat > "$TOPICS/demo/pkg-norestartfn.sh" <<SH
check()  { return 0; }
update() { return 10; }
SH
cat > "$TOPICS/demo/pkg-badref.sh"      <<SH
check()  { return 0; }
update() { return 10; }
SH
# service items: restart() drops a sentinel proving the bounce ran.
cat > "$TOPICS/demo/svc-a.sh" <<SH
check()   { return 0; }
restart() { : > "$SENT/svc-a-RESTARTED"; }
SH
cat > "$TOPICS/demo/svc-b.sh" <<SH
check()   { return 0; }
restart() { : > "$SENT/svc-b-RESTARTED"; }
SH
# service with NO restart() → graceful no-op (engine logs "no restart()").
cat > "$TOPICS/demo/svc-nofn.sh" <<SH
check()   { return 0; }
SH

export MESH_INSTALL_STATE_DIR="$STATE"
restarted() { [[ -f "$SENT/$1-RESTARTED" ]]; }
clean()     { rm -f "$SENT"/* 2>/dev/null; }
# categories forced OFF: the autoupdate flag alone drives the update pass.
engine() {
  ( unset MESH_UPDATE_AGENT_CLIS MESH_UPDATE_CLI_TOOLS MESH_UPDATE_RUNTIMES_DBS \
          MESH_AUTOUPDATE_FILE MESH_AUTOUPDATE_ALIAS
    bash "$ENGINE" --topics-dir "$TOPICS" --platform mac --bundle demo/b --update "$@" ) \
    > "$ROOT/log" 2>&1
}

# ── 1. changed (rc 10) restarts the linked service; no-change (rc 0) does not ──
clean
engine; rc=$?
[[ "$rc" -eq 0 ]]      && ok "update pass exits 0 with restart_service wiring"        || bad "update pass rc=$rc"
restarted svc-a       && ok "CHANGED update (rc 10) restarts its linked service"      || bad "changed update did NOT restart linked service"
! restarted svc-b     && ok "NO-change update (rc 0) does NOT restart its service"    || bad "no-change update wrongly restarted the service"

# ── 2. graceful handling: service without restart(), and a dangling ref ──
grep -q "svc-nofn" "$ROOT/log" && grep -qi "no restart" "$ROOT/log" \
                      && ok "restart_service with no restart() logs a graceful skip"  || bad "missing restart() not logged gracefully"
grep -qi "ghost" "$ROOT/log" && grep -qi "not found" "$ROOT/log" \
                      && ok "restart_service naming an absent sibling logs a skip"    || bad "dangling restart_service not logged"

# ── 3. --dry-run restarts nothing ──
clean
engine --dry-run; rc=$?
[[ "$rc" -eq 0 ]]      && ok "--dry-run exits 0"                                       || bad "--dry-run rc=$rc"
! restarted svc-a     && ok "--dry-run dropped NO restart sentinel (no mutation)"      || bad "--dry-run restarted a service"

# ── 4. brew_formula_update returns 10 only on a real upgrade ──
cat > "$ROOT/fakebrew" <<'SH'
#!/usr/bin/env bash
[[ "$1" == "outdated" ]] && { [[ "${FAKE_OUTDATED:-1}" == 1 ]] && echo "moshi-hook"; exit 0; }
exit 0
SH
chmod +x "$ROOT/fakebrew"
( # shellcheck source=/dev/null
  . "$WS/scripts/lib/installers/brew-formula.sh"
  export BREW_BIN="$ROOT/fakebrew"
  FAKE_OUTDATED=1 brew_formula_update moshi-hook >/dev/null 2>&1; [[ $? -eq 10 ]] ) \
  && ok "brew_formula_update returns 10 (sentinel) when the formula was outdated" \
  || bad "brew_formula_update did not return 10 on an upgrade"
( # shellcheck source=/dev/null
  . "$WS/scripts/lib/installers/brew-formula.sh"
  export BREW_BIN="$ROOT/fakebrew"
  FAKE_OUTDATED=0 brew_formula_update moshi-hook >/dev/null 2>&1; [[ $? -eq 0 ]] ) \
  && ok "brew_formula_update returns 0 when the formula was already latest" \
  || bad "brew_formula_update did not return 0 when already latest"

# ── 5. the real moshi service scripts define restart() ──
grep -qE '^restart\(\)' "$WS/topics/ai/moshi-hook-service-mac.sh" \
  && ok "moshi-hook-service-mac.sh defines restart()"  || bad "mac moshi service has no restart()"
grep -qE '^restart\(\)' "$WS/topics/ai/moshi-hook-service-wsl.sh" \
  && ok "moshi-hook-service-wsl.sh defines restart()"  || bad "wsl moshi service has no restart()"

# ── 6. yaml-parse emits _RESTART_SERVICE; the ai manifest wires moshi-hook ──
parsed="$(bash "$WS/scripts/lib/yaml-parse.sh" < "$TOPICS/demo/manifest.yaml" 2>/dev/null)"
echo "$parsed" | grep -qE '_RESTART_SERVICE="?svc-a"?' \
  && ok "yaml-parse emits _RESTART_SERVICE for a wired item" || bad "yaml-parse did not emit _RESTART_SERVICE"
ai_parsed="$(bash "$WS/scripts/lib/yaml-parse.sh" < "$WS/topics/ai/manifest.yaml" 2>/dev/null)"
echo "$ai_parsed" | grep -qE '_RESTART_SERVICE="?moshi-hook-mac-service"?' \
  && ok "ai manifest wires moshi-hook-mac → moshi-hook-mac-service" || bad "moshi-hook-mac restart_service not wired in ai manifest"

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
