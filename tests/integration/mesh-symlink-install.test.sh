#!/usr/bin/env bash
# tests/integration/mesh-symlink-install.test.sh
#
# Regression suite for setup.sh's install_mesh_symlink() — the installer step
# that points ~/.local/bin/mesh at the workstation's bin/mesh.
#
# THE BUG (v1→v2 migration, ULTRON 2026-06-06): a machine provisioned by the
# old v1 system has a REGULAR FILE at ~/.local/bin/mesh (the pre-rename
# `scripts/mesh` dispatcher, no doctor/adopt). The old guard saw "not a symlink"
# and just warn+returned, so `setup.sh` left the stale dispatcher in place
# forever — `mesh doctor` fell through to help on every migrated machine.
# Same v1-stale-artifact-reconciliation class as engine --adopt (T-ADOPT).
#
# Fix: the installer TAKES OWNERSHIP — when the destination is a regular file
# (not the correct symlink), back it up to mesh.bak-<TS> (the deploy driver's
# pattern) and install the bin/mesh symlink. Self-heals on every migrated box.
#
# Tests the REAL production function by sed-extracting it from setup.sh and
# running it against a fake $HOME — no copy, no full setup.sh run (which would
# need OS detection + sudo + the engine).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
BOOT="$REPO_ROOT/setup.sh"
# shellcheck source=../lib/assert.sh
source "$SELF_DIR/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-symlink-install.XXXXXX)"
trap '[[ -d "$SANDBOX" ]] && rm -rf "$SANDBOX"' EXIT

# A fake workstation checkout: install_mesh_symlink() reads target="$HERE/bin/mesh".
REPO_FAKE="$SANDBOX/ws"
mkdir -p "$REPO_FAKE/bin"
printf '#!/usr/bin/env bash\n# bin/mesh v2 (has doctor/adopt)\n' > "$REPO_FAKE/bin/mesh"

# Pull in the real function definition (column-0 closing brace → clean range)
# and the globals it reads. warn() is provided by setup.sh's logging lib at
# runtime; stub it here.
eval "$(sed -n '/^install_mesh_symlink() {/,/^}/p' "$BOOT")"
warn() { echo "warn: $*" >&2; }
HERE="$REPO_FAKE"   # global read by install_mesh_symlink as the symlink target dir
DRY_RUN=0

if ! declare -F install_mesh_symlink >/dev/null; then
    echo "FATAL: could not extract install_mesh_symlink() from $BOOT" >&2
    exit 1
fi

# ─── Case 1: v1 orphan REGULAR FILE is reconciled to the symlink (THE BUG) ───
HOME="$SANDBOX/c1"; mkdir -p "$HOME/.local/bin"
printf 'OLD-V1-SCRIPTS-MESH-DISPATCHER\n' > "$HOME/.local/bin/mesh"   # regular file
install_mesh_symlink
ASSERT_MSG="Case 1a: regular-file mesh is replaced by a symlink" assert_true '[[ -L "$HOME/.local/bin/mesh" ]]'
assert_eq    "$(readlink "$HOME/.local/bin/mesh" 2>/dev/null)" "$REPO_FAKE/bin/mesh" \
    "Case 1b: symlink points at the workstation bin/mesh"
bak="$(compgen -G "$HOME/.local/bin/mesh.bak-*" 2>/dev/null | head -1 || true)"
ASSERT_MSG="Case 1c: the original regular file is backed up to mesh.bak-<TS>" assert_true '[[ -n "$bak" ]]'
assert_file_contains "$bak" "OLD-V1-SCRIPTS-MESH-DISPATCHER" \
    "Case 1d: backup preserves the original dispatcher (not deleted)"

# ─── Case 2: an already-correct symlink is a no-op (no churn, no backup) ─────
HOME="$SANDBOX/c2"; mkdir -p "$HOME/.local/bin"
ln -sf "$REPO_FAKE/bin/mesh" "$HOME/.local/bin/mesh"
install_mesh_symlink
ASSERT_MSG="Case 2a: a correct symlink stays a symlink" assert_true '[[ -L "$HOME/.local/bin/mesh" ]]'
ASSERT_MSG="Case 2b: no backup churned for an already-correct symlink" assert_false 'compgen -G "$HOME/.local/bin/mesh.bak-*" >/dev/null 2>&1'

# ─── Case 3: absent destination → symlink created (unchanged happy path) ─────
HOME="$SANDBOX/c3"; mkdir -p "$HOME/.local/bin"
install_mesh_symlink
ASSERT_MSG="Case 3a: absent destination → symlink created" assert_true '[[ -L "$HOME/.local/bin/mesh" ]]'
assert_eq    "$(readlink "$HOME/.local/bin/mesh" 2>/dev/null)" "$REPO_FAKE/bin/mesh" \
    "Case 3b: created symlink points at bin/mesh"

# ─── Case 4: DRY_RUN never mutates a v1 orphan (plan only) ───────────────────
HOME="$SANDBOX/c4"; mkdir -p "$HOME/.local/bin"
printf 'OLD\n' > "$HOME/.local/bin/mesh"
DRY_RUN=1 install_mesh_symlink
DRY_RUN=0
ASSERT_MSG="Case 4a: dry-run leaves the regular file untouched" assert_true '[[ -f "$HOME/.local/bin/mesh" && ! -L "$HOME/.local/bin/mesh" ]]'
ASSERT_MSG="Case 4b: dry-run writes no backup" assert_false 'compgen -G "$HOME/.local/bin/mesh.bak-*" >/dev/null 2>&1'

summary
