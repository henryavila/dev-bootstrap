#!/usr/bin/env bash
# Regression: auto-update package throttle crashes on Linux with
#   File: unbound variable
#
# ROOT CAUSE (confirmed 2026-07-23 on GNU coreutils 9.4 / bash 5.x + set -u):
#   _mtime() tried BSD first: `stat -f %m "$path" || stat -c %Y "$path"`.
#   On Linux, GNU `stat -f` is `--file-system` (not BSD format). It still
#   writes multi-line filesystem status starting with `  File: "..."` to
#   stdout for the real path, exits non-zero for the bogus `%m` operand,
#   then the `||` GNU branch appends a real epoch. The capture is therefore
#   multi-line garbage + digits. Arithmetic
#     (( now - mtime < interval ))
#   tokenizes the word `File` as a variable name → under `set -u`:
#     File: unbound variable
#   at _package_update_throttled (auto-update.sh ~line 812).
#
# This is hit whenever last-package-update exists and the package phase is
# considered (autoupdate items or category opt-in) — i.e. almost every
# `mesh update` / `mesh update -f` on Linux after the first package pass.
#
# Correct pattern (see scripts/internal/mesh-snap _mtime_epoch): GNU first,
# only accept a branch when that command's exit status is 0, and reject
# non-numeric captures before arithmetic.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
AU="$REPO_ROOT/scripts/runners/auto-update.sh"
# shellcheck source=../lib/assert.sh
source "$SELF_DIR/../lib/assert.sh"

# ── helpers under test (mirrors production; updated when production changes) ─
# We also exercise the REAL auto-update.sh end-to-end below. These inline
# copies pin the helper contract so a future reintroduction of BSD-first is
# caught even if the integration fixture drifts.
_mtime_broken() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

_mtime_fixed() {
    local p="$1" out
    out="$(stat -c %Y "$p" 2>/dev/null)" && { printf '%s\n' "$out"; return 0; }
    out="$(stat -f %m "$p" 2>/dev/null)" && { printf '%s\n' "$out"; return 0; }
    return 1
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
: > "$TMP/stamp"

# ── 1. Prove the broken helper still produces multi-line "File:" garbage ──
# (documents the defect class; if a future coreutils change stops emitting
# "File:" this assert may need updating, but the pure-digit contract remains.)
broken="$(_mtime_broken "$TMP/stamp" || true)"
if [[ "$broken" == *$'\n'* ]] || [[ "$broken" == *File:* ]]; then
    pass "broken BSD-first helper pollutes capture with multi-line/File: (defect class live on this host)"
else
    # On pure BSD hosts the "broken" helper is accidentally fine; still require
    # that the fixed helper is pure digits.
    pass "broken helper happens to be clean on this stat(1) (BSD-like); still exercising fixed path"
fi

# ── 2. Fixed helper: pure epoch digits, single line ──
fixed="$(_mtime_fixed "$TMP/stamp")"
fix_rc=$?
assert_eq "$fix_rc" "0" "fixed _mtime exits 0 for an existing path"
if [[ "$fixed" =~ ^[0-9]+$ ]]; then
    pass "fixed _mtime is pure digits"
else
    fail "fixed _mtime is pure digits (got: $(printf %q "$fixed"))"
fi
if [[ "$fixed" != *$'\n'* ]]; then
    pass "fixed _mtime is a single line"
else
    fail "fixed _mtime is a single line (got multi-line capture)"
fi
assert_not_contains "$fixed" "File:" "fixed _mtime never embeds File: filesystem dump"

# ── 3. Arithmetic under set -u must not crash with File: unbound ──
# Reproduce the exact surface symptom with the broken capture, then prove the
# fixed capture is safe.
now="$(date +%s)"
interval=86400
bash -c 'set -uo pipefail; now="$1"; mtime="$2"; interval="$3"; (( now - mtime < interval ))' \
    bash "$now" "$broken" "$interval" 2>"$TMP/arith-broken.err"
broken_arith_rc=$?
if grep -q 'File: unbound variable' "$TMP/arith-broken.err" 2>/dev/null \
    || grep -qi 'unbound variable' "$TMP/arith-broken.err" 2>/dev/null \
    || [[ "$broken_arith_rc" -ne 0 && "$broken_arith_rc" -ne 1 ]]; then
    pass "broken mtime + arithmetic under set -u is the crash class (rc=$broken_arith_rc)"
else
    # If this host's broken helper is clean (BSD), arithmetic may simply work.
    pass "broken-path arithmetic did not crash on this host (rc=$broken_arith_rc); fixed path still required"
fi

bash -c 'set -uo pipefail; now="$1"; mtime="$2"; interval="$3"; (( now - mtime < interval )); exit $?' \
    bash "$now" "$fixed" "$interval" 2>"$TMP/arith-fixed.err"
fixed_arith_rc=$?
if [[ "$fixed_arith_rc" -eq 0 || "$fixed_arith_rc" -eq 1 ]]; then
    pass "fixed mtime arithmetic exits 0/1 only (no crash; rc=$fixed_arith_rc)"
else
    fail "fixed mtime arithmetic exits 0/1 only (no crash; rc=$fixed_arith_rc)"
fi
assert_not_contains "$(cat "$TMP/arith-fixed.err" 2>/dev/null || true)" "unbound variable" \
    "fixed mtime arithmetic never emits unbound variable"

# ── 4. End-to-end: real auto-update.sh throttle path with stamp present ──
# Minimal workstation-shaped fixture so run_update_phase reaches
# _package_update_throttled (autoupdate item present + stamp exists).
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

WS="$TMP/ws"
mkdir -p "$WS/scripts/runners" "$WS/scripts/lib" "$WS/topics/demo" "$TMP/state" "$TMP/config/mesh"

# Real motor under test (path must match what conf points at).
cp "$AU" "$WS/scripts/runners/auto-update.sh"
# Stub engine — must not be reached when throttled.
cat > "$WS/scripts/lib/install-engine.sh" <<'SH'
#!/usr/bin/env bash
echo "ENGINE_RAN" >&2
exit 0
SH
chmod +x "$WS/scripts/lib/install-engine.sh"

# Role detection: workstation = has setup.sh + topics/
cat > "$WS/setup.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$WS/setup.sh"

# At least one autoupdate: true so the package phase is considered.
cat > "$WS/topics/demo/manifest.yaml" <<'YAML'
topic:
  label: Demo
  order: 1
bundles:
  - name: b
    items:
      - name: flagged
        type: custom
        script: ./flagged.sh
        autoupdate: true
YAML
: > "$WS/topics/demo/flagged.sh"

# state-dir.sh is sourced by auto-update — provide the real one.
cp "$REPO_ROOT/scripts/lib/state-dir.sh" "$WS/scripts/lib/state-dir.sh"

git init -q "$WS"
git -C "$WS" add setup.sh scripts topics
git -C "$WS" commit -qm fixture
git -C "$WS" branch -M main
# Bare remote so fetch can succeed (up-to-date).
git init -q --bare "$TMP/remote.git"
git -C "$WS" remote add origin "$TMP/remote.git"
git -C "$WS" push -q -u origin main

printf 'AUTO_UPDATE_REPOS=("%s")\n' "$WS" > "$TMP/conf"
: > "$TMP/state/last-package-update"
printf '%s\n' "$(git -C "$WS" rev-parse HEAD)" > "$TMP/state/last-applied-$(basename "$WS")"
# selections.list present so a non-throttled path would proceed past that gate
# (we assert engine does NOT run when throttled).
mkdir -p "$TMP/config/mesh"
: > "$TMP/config/mesh/selections.list"

# Seed last-applied under the repo basename keys the motor uses.
# The motor keys last-applied by basename of the repo path.
printf '%s\n' "$(git -C "$WS" rev-parse HEAD)" > "$TMP/state/last-applied-ws"

# Incremental (not --full): --full would request sudo for setup.sh and abort
# the fixture. The crash was on the package-throttle path, which runs after
# the per-repo loop on both incremental and full runs.
out="$(
    AUTO_UPDATE_CONF="$TMP/conf" \
    AUTO_UPDATE_STATE_DIR="$TMP/state" \
    XDG_CONFIG_HOME="$TMP/config" \
    HOME="$TMP/home" \
    NO_COLOR=1 \
    bash "$WS/scripts/runners/auto-update.sh" 2>&1
)"
rc=$?

assert_not_contains "$out" "unbound variable" \
    "real auto-update with last-package-update stamp never emits unbound variable"
assert_not_contains "$out" "File: unbound" \
    "real auto-update never surfaces File: unbound variable"
assert_eq "$rc" "0" \
    "auto-update exits 0 when package phase is throttled (rc=$rc)"
assert_not_contains "$out" "ENGINE_RAN" \
    "throttled package phase does not spawn install-engine"
assert_not_contains "$out" "version-aware update phase" \
    "throttled run does not enter the package update phase notice"

# ── 5. Force bypass still must not crash and DOES run the engine ──
out_force="$(
    AUTO_UPDATE_CONF="$TMP/conf" \
    AUTO_UPDATE_STATE_DIR="$TMP/state" \
    XDG_CONFIG_HOME="$TMP/config" \
    HOME="$TMP/home" \
    NO_COLOR=1 \
    MESH_UPDATE_FORCE=1 \
    bash "$WS/scripts/runners/auto-update.sh" 2>&1
)"
rc_force=$?
assert_not_contains "$out_force" "unbound variable" \
    "MESH_UPDATE_FORCE=1 path never emits unbound variable"
assert_eq "$rc_force" "0" "forced package pass exits 0"
assert_contains "$out_force" "ENGINE_RAN" \
    "MESH_UPDATE_FORCE=1 bypasses throttle and runs the engine"

# ── 6. Source-level guard: production _mtime must try GNU (-c) before BSD (-f) ──
# Cheap static contract so a refactor that reverts to BSD-first fails even if
# the runtime host masks the bug (e.g. pure BSD CI).
mtime_src="$(sed -n '/^_mtime()/,/^}/p' "$AU")"
# Require -c before -f in the function body.
c_pos="$(printf '%s' "$mtime_src" | tr '\n' ' ' | grep -bo 'stat -c' | head -1 | cut -d: -f1 || true)"
f_pos="$(printf '%s' "$mtime_src" | tr '\n' ' ' | grep -bo 'stat -f' | head -1 | cut -d: -f1 || true)"
if [[ -n "$c_pos" && -n "$f_pos" && "$c_pos" -lt "$f_pos" ]]; then
    pass "production _mtime tries GNU stat -c before BSD stat -f"
else
    fail "production _mtime must try GNU stat -c before BSD stat -f (got: $mtime_src)"
fi
# Reject the classic one-liner anti-pattern that caused the bug.
if grep -qE 'stat -f %m .* \|\| stat -c %Y' "$AU"; then
    fail "production still has BSD-first one-liner: stat -f %m || stat -c %Y"
else
    pass "production no longer uses BSD-first stat -f %m || stat -c %Y one-liner"
fi

summary
