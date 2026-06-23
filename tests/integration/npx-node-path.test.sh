#!/usr/bin/env bash
# tests/integration/npx-node-path.test.sh
#
# The npx driver runs `npx -y <spec>`, but `npx` ships with Node and mesh installs
# Node via fnm (~/.local/share/fnm) — whose shell activation the engine's
# non-interactive per-item subshell never runs. On a FRESH bootstrap (Node
# installed earlier in the same run) `npx` is therefore not on PATH yet and the
# item dies with rc 127 — the live CI-smoke failure for claude-code/claudebar.
# The driver now calls _npx_ensure_on_path() to activate the fnm-managed default
# Node first. This pins the contract WITHOUT needing fnm/Node present:
#   - the helper exists and every npx verb calls it
#   - npx already on PATH ⇒ fast no-op (returns 0, never touches fnm)
#   - npx absent AND no fnm ⇒ returns non-zero gracefully (no set -e abort)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
SRC="$WS/scripts/lib/installers/npx.sh"

passed=0; failed=0
ok()  { passed=$((passed+1)); echo "  ✓ $1"; }
bad() { failed=$((failed+1)); echo "  ✗ $1" >&2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ── static: helper exists + every verb activates Node before calling npx ──
# shellcheck source=/dev/null
. "$SRC"
declare -f _npx_ensure_on_path >/dev/null \
  && ok "npx.sh defines _npx_ensure_on_path" || bad "no _npx_ensure_on_path helper"
miss=""
for v in npx_install npx_verify npx_rollback npx_update; do
    declare -f "$v" | grep -q "_npx_ensure_on_path" || miss="$miss $v"
done
[[ -z "$miss" ]] && ok "every npx verb calls _npx_ensure_on_path" \
                 || bad "verbs missing the activation call:$miss"

# ── behavioural: npx already on PATH ⇒ no-op success ──
mkdir -p "$ROOT/bin"; printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/npx"; chmod +x "$ROOT/bin/npx"
( PATH="$ROOT/bin:$PATH"; _npx_ensure_on_path ) \
  && ok "_npx_ensure_on_path is a no-op (rc 0) when npx is already on PATH" \
  || bad "_npx_ensure_on_path failed even though npx was on PATH"

# ── behavioural: npx absent + no fnm ⇒ graceful non-zero, no set -e abort ──
mkdir -p "$ROOT/eh"
# SC2123: emptying PATH is the point (simulate no node/fnm tools). SC1090: dynamic source.
# shellcheck disable=SC2123,SC1090
out="$(set -e; PATH=""; HOME="$ROOT/eh"; . "$SRC"
       if _npx_ensure_on_path; then echo FOUND; else echo ABSENT; fi)"; rc=$?
{ [[ "$rc" -eq 0 ]] && [[ "$out" == "ABSENT" ]]; } \
  && ok "npx absent + no fnm ⇒ helper returns non-zero gracefully (no set -e crash)" \
  || bad "helper mishandled the no-node case (rc=$rc out=$out)"

# ── the npm-global driver has the same Node-on-PATH dependency: same guard ──
NPM_SRC="$WS/scripts/lib/installers/npm-global.sh"
# shellcheck source=/dev/null
. "$NPM_SRC"
declare -f _npm_global_ensure_on_path >/dev/null \
  && ok "npm-global.sh defines _npm_global_ensure_on_path" || bad "no _npm_global_ensure_on_path helper"
nmiss=""
for v in npm_global_check npm_global_install npm_global_update; do
    declare -f "$v" | grep -q "_npm_global_ensure_on_path" || nmiss="$nmiss $v"
done
[[ -z "$nmiss" ]] && ok "every npm-global verb calls _npm_global_ensure_on_path" \
                  || bad "npm-global verbs missing the activation call:$nmiss"
mkdir -p "$ROOT/nbin"; printf '#!/bin/sh\nexit 0\n' > "$ROOT/nbin/npm"; chmod +x "$ROOT/nbin/npm"
( PATH="$ROOT/nbin:$PATH"; _npm_global_ensure_on_path ) \
  && ok "_npm_global_ensure_on_path is a no-op (rc 0) when npm is already on PATH" \
  || bad "_npm_global_ensure_on_path failed even though npm was on PATH"

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
