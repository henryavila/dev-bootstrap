#!/usr/bin/env bash
# tests/integration/clean.test.sh
#
# Contract suite for `mesh clean` (scripts/runners/clean.sh) — the OS-aware,
# registry-driven disk-reclaim verb (initiative disk-reclaim).
#
# The runner iterates scripts/lib/cleaners/*.sh (each a module declaring
# cleaner_<name>_{tier,desc,applies,measure,clean}) and:
#   • DRY-RUN by default — measures, deletes NOTHING;
#   • --apply  — runs Tier-1 cleaners (needs --yes when non-interactive);
#   • --deep   — also runs Tier-2 cleaners (heavy, re-downloadable);
#   • --compact — WSL-only handoff that prints the `wsl --set-sparse` step;
#                 a clear no-op off-WSL.
#
# Drives the REAL runner against a fake $HOME so no real cache is touched.
# MESH_CLEAN_OS overrides detect-os so the apt/journal/brew (OS-gated, sudo)
# cleaners stay out of the sandbox — only the path-based user-cache cleaners
# run, deterministically.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/scripts/runners/clean.sh"
# shellcheck source=../lib/assert.sh
source "$SELF_DIR/../lib/assert.sh"

if [[ ! -f "$RUNNER" ]]; then
    echo "FATAL: runner not found at $RUNNER" >&2
    exit 1
fi

SANDBOX="$(mktemp -d -t mesh-clean.XXXXXX)"
trap '[[ -d "$SANDBOX" ]] && rm -rf "$SANDBOX"' EXIT

# Build a fake $HOME with Tier-1 + Tier-2 caches AND must-never-touch data.
mk_home() {
    local h="$1"
    mkdir -p \
        "$h/.npm/_cacache" "$h/.npm/_npx" "$h/.npm/_logs" \
        "$h/.cache/pip" "$h/.cache/uv" \
        "$h/.cache/ms-playwright" "$h/.cache/torch" \
        "$h/.local/share/important" "$h/proj/src"
    head -c 200000 /dev/zero > "$h/.npm/_cacache/blob"        2>/dev/null
    head -c 100000 /dev/zero > "$h/.cache/pip/blob"           2>/dev/null
    head -c 300000 /dev/zero > "$h/.cache/ms-playwright/chrome" 2>/dev/null
    head -c  50000 /dev/zero > "$h/.cache/torch/model.pt"     2>/dev/null
    echo "do-not-touch"  > "$h/.npm/_logs/keep.log"
    echo "user-data"     > "$h/.local/share/important/data.db"
    echo "print('hi')"   > "$h/proj/src/main.py"
}

run() { HOME="$1" MESH_CLEAN_OS="$2" NO_COLOR=1 bash "$RUNNER" "${@:3}"; }

# ─── Case 1: dry-run is the DEFAULT and mutates nothing ──────────────────────
H="$SANDBOX/dry"; mk_home "$H"
out="$(run "$H" mac 2>&1)"; rc=$?
assert_eq "$rc" 0 "Case 1a: dry-run exits 0"
assert_contains "$out" "dry-run" "Case 1b: dry-run announces itself"
assert_contains "$out" "npm"     "Case 1c: dry-run lists the npm cleaner"
ASSERT_MSG="Case 1d: dry-run deletes nothing (npm cache intact)" assert_true '[[ -f "$H/.npm/_cacache/blob" ]]'
ASSERT_MSG="Case 1e: dry-run pip cache intact"                   assert_true '[[ -f "$H/.cache/pip/blob" ]]'

# ─── Case 2: --apply removes Tier-1 ONLY; never data/source/Tier-2 ───────────
H="$SANDBOX/apply"; mk_home "$H"
out="$(run "$H" mac --apply --yes 2>&1)"; rc=$?
assert_eq "$rc" 0 "Case 2a: --apply exits 0"
ASSERT_MSG="Case 2b: --apply removes npm _cacache (Tier-1)"          assert_false '[[ -e "$H/.npm/_cacache" ]]'
ASSERT_MSG="Case 2c: --apply removes pip cache (Tier-1)"             assert_false '[[ -e "$H/.cache/pip" ]]'
ASSERT_MSG="Case 2d: --apply removes uv cache (Tier-1)"              assert_false '[[ -e "$H/.cache/uv" ]]'
ASSERT_MSG="Case 2e: --apply preserves npm _logs (not a target)"    assert_true  '[[ -e "$H/.npm/_logs/keep.log" ]]'
ASSERT_MSG="Case 2f: --apply WITHOUT --deep preserves Tier-2 (playwright)" assert_true '[[ -e "$H/.cache/ms-playwright/chrome" ]]'
ASSERT_MSG="Case 2g: --apply NEVER touches ~/.local/share data"     assert_true  '[[ -e "$H/.local/share/important/data.db" ]]'
ASSERT_MSG="Case 2h: --apply NEVER touches source files"            assert_true  '[[ -e "$H/proj/src/main.py" ]]'

# ─── Case 3: --deep also removes Tier-2 (still never data) ───────────────────
H="$SANDBOX/deep"; mk_home "$H"
run "$H" mac --apply --deep --yes >/dev/null 2>&1
ASSERT_MSG="Case 3a: --deep removes Tier-2 playwright" assert_false '[[ -e "$H/.cache/ms-playwright" ]]'
ASSERT_MSG="Case 3b: --deep removes Tier-2 torch"      assert_false '[[ -e "$H/.cache/torch" ]]'
ASSERT_MSG="Case 3c: --deep still removes Tier-1 npm"  assert_false '[[ -e "$H/.npm/_cacache" ]]'
ASSERT_MSG="Case 3d: --deep still never touches data"  assert_true  '[[ -e "$H/.local/share/important/data.db" ]]'

# ─── Case 4: idempotent re-run (second --apply is clean, exit 0) ─────────────
H="$SANDBOX/idem"; mk_home "$H"
run "$H" mac --apply --deep --yes >/dev/null 2>&1
out="$(run "$H" mac --apply --deep --yes 2>&1)"; rc=$?
assert_eq "$rc" 0 "Case 4: second --apply exits 0 (idempotent)"

# ─── Case 5: --apply without --yes, non-interactive → refuse, delete nothing ─
H="$SANDBOX/noyes"; mk_home "$H"
out="$(HOME="$H" MESH_CLEAN_OS=mac NO_COLOR=1 NON_INTERACTIVE=1 bash "$RUNNER" --apply </dev/null 2>&1)"; rc=$?
assert_ne "$rc" 0 "Case 5a: --apply w/o --yes (non-interactive) refuses (nonzero)"
ASSERT_MSG="Case 5b: refused --apply deleted nothing" assert_true '[[ -e "$H/.npm/_cacache" ]]'

# ─── Case 6: --compact off-WSL is a clear no-op, no deletions ────────────────
H="$SANDBOX/compmac"; mk_home "$H"
out="$(run "$H" mac --compact 2>&1)"; rc=$?
assert_eq "$rc" 0 "Case 6a: --compact off-WSL exits 0"
assert_contains "$out" "WSL" "Case 6b: --compact off-WSL explains it is WSL-only"
ASSERT_MSG="Case 6c: --compact-only run made no deletions" assert_true '[[ -e "$H/.npm/_cacache" ]]'

# ─── Case 7: --compact on WSL prints the set-sparse handoff for the distro ───
H="$SANDBOX/compwsl"; mk_home "$H"
out="$(HOME="$H" MESH_CLEAN_OS=wsl WSL_DISTRO_NAME=Ubuntu NO_COLOR=1 bash "$RUNNER" --compact 2>&1)"; rc=$?
assert_eq "$rc" 0 "Case 7a: --compact on WSL exits 0"
assert_contains "$out" "set-sparse" "Case 7b: --compact on WSL prints the set-sparse command"
assert_contains "$out" "Ubuntu"     "Case 7c: --compact names the distro (WSL_DISTRO_NAME)"

# ─── Case 8: OS/tool guard — apt cleaner is skipped on mac ───────────────────
H="$SANDBOX/guard"; mk_home "$H"
out="$(run "$H" mac 2>&1)"
assert_not_contains "$out" "apt package" "Case 8: apt cleaner skipped on mac (OS guard)"

# ─── Case 9: after --apply on WSL (no --compact), nudge the Phase-B handoff ───
# Point MESH_CLEANERS_DIR at a dir holding only _lib.sh so NO real cleaner runs
# (the apt/journal cleaners would otherwise sudo on a real WSL box) — this
# exercises the post-apply reminder path in isolation.
EMPTY="$SANDBOX/nocleaners"; mkdir -p "$EMPTY"
ln -s "$REPO_ROOT/scripts/lib/cleaners/_lib.sh" "$EMPTY/_lib.sh"
mkdir -p "$SANDBOX/r1" "$SANDBOX/r2"
out="$(HOME="$SANDBOX/r1" MESH_CLEAN_OS=wsl MESH_CLEANERS_DIR="$EMPTY" NO_COLOR=1 bash "$RUNNER" --apply --yes 2>&1)"
assert_contains "$out" "mesh clean --compact" "Case 9a: WSL --apply nudges the Phase-B compaction step"
out="$(HOME="$SANDBOX/r2" MESH_CLEAN_OS=mac MESH_CLEANERS_DIR="$EMPTY" NO_COLOR=1 bash "$RUNNER" --apply --yes 2>&1)"
assert_not_contains "$out" "mesh clean --compact" "Case 9b: mac --apply does NOT nudge compaction (WSL-only)"

summary
