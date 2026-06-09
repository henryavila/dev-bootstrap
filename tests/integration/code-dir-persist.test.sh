#!/usr/bin/env bash
# tests/integration/code-dir-persist.test.sh
#
# Regression suite for setup.sh's persist_code_dir() — the post-menu step that
# lifts CODE_DIR from params.env into ~/.config/mesh/config.env so the
# interactive shell reads the chosen dev root.
#
# THE REGRESSION (F9.6 menu rebuild): the old whiptail menu asked for CODE_DIR
# and persisted it to config.env; the Ink rebuild dropped the prompt, so nothing
# populated CODE_DIR and mesh-identity's shell/aliases.sh (auto-cd + tmux
# shortcuts, which source config.env) silently fell back to $HOME. The new
# dev-root screen writes CODE_DIR to params.env; this function bridges it into
# config.env without disturbing the file's other lines (repo paths, the
# AUTO_UPDATE_REPOS bash array).
#
# Tests the REAL production function by sed-extracting it from setup.sh and
# running it against a fake config dir — no full setup.sh run.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
BOOT="$REPO_ROOT/setup.sh"
# shellcheck source=../lib/assert.sh
source "$SELF_DIR/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-code-dir-persist.XXXXXX)"
trap '[[ -d "$SANDBOX" ]] && rm -rf "$SANDBOX"' EXIT

# Pull in the real function + stub the globals/loggers it reads at runtime.
eval "$(sed -n '/^persist_code_dir() {/,/^}/p' "$BOOT")"
info() { :; }
DRY_RUN=0

if ! declare -F persist_code_dir >/dev/null; then
    echo "FATAL: could not extract persist_code_dir from $BOOT" >&2
    exit 1
fi

# A params.env quoted exactly as the menu's writeParams() would emit it (%q-ish).
seed_params() {
    local dir="$1" code="$2"
    mkdir -p "$dir"
    {
        printf '# mesh resolved options\n'
        [[ -n "$code" ]] && printf 'CODE_DIR=%q\n' "$code"
        printf 'MESH_IDENTITY_REPO=git@github.com:me/x.git\n'
    } > "$dir/params.env"
}

# ─── Case 1: absent config.env → created with the CODE_DIR line ──────────────
SELECTIONS_DIR="$SANDBOX/c1"; seed_params "$SELECTIONS_DIR" "$SANDBOX/c1/projects"
CODE_DIR=""; persist_code_dir
assert_file_exists "$SELECTIONS_DIR/config.env" "Case 1a: config.env is created"
assert_file_contains "$SELECTIONS_DIR/config.env" "CODE_DIR=$SANDBOX/c1/projects" \
    "Case 1b: the chosen dev root is written"
assert_eq "$CODE_DIR" "$SANDBOX/c1/projects" "Case 1c: CODE_DIR is exported for the engine pass"

# ─── Case 2: existing config.env → idempotent upsert, other lines preserved ──
SELECTIONS_DIR="$SANDBOX/c2"; seed_params "$SELECTIONS_DIR" "$SANDBOX/c2/code"
cat > "$SELECTIONS_DIR/config.env" <<EOF
# mesh per-host config
MESH_WORKSTATION_DIR=\$HOME/mesh-workstation
CODE_DIR=/old/stale/value
AUTO_UPDATE_REPOS=(
    "\$MESH_WORKSTATION_DIR"
)
EOF
CODE_DIR=""; persist_code_dir; persist_code_dir   # run twice → idempotent
assert_eq "$(grep -c '^CODE_DIR=' "$SELECTIONS_DIR/config.env")" "1" \
    "Case 2a: exactly one CODE_DIR line after two runs"
assert_file_contains "$SELECTIONS_DIR/config.env" "CODE_DIR=$SANDBOX/c2/code" \
    "Case 2b: the stale value is replaced by the new one"
assert_not_contains "$(cat "$SELECTIONS_DIR/config.env")" "/old/stale/value" \
    "Case 2c: the stale CODE_DIR line is gone"
assert_file_contains "$SELECTIONS_DIR/config.env" 'AUTO_UPDATE_REPOS=(' \
    "Case 2d: the bash array is preserved untouched"
assert_file_contains "$SELECTIONS_DIR/config.env" 'MESH_WORKSTATION_DIR=' \
    "Case 2e: other config lines are preserved"

# ─── Case 3: params.env without CODE_DIR → no-op (no config.env created) ─────
SELECTIONS_DIR="$SANDBOX/c3"; seed_params "$SELECTIONS_DIR" ""
CODE_DIR=""; persist_code_dir
assert_false "[[ -f '$SELECTIONS_DIR/config.env' ]]" \
    "Case 3a: no CODE_DIR in params → config.env is not created"

# ─── Case 4: DRY_RUN never writes ────────────────────────────────────────────
SELECTIONS_DIR="$SANDBOX/c4"; seed_params "$SELECTIONS_DIR" "$SANDBOX/c4/dev"
# shellcheck disable=SC2034  # trailing DRY_RUN reset for next case
CODE_DIR=""; DRY_RUN=1 persist_code_dir; DRY_RUN=0
assert_false "[[ -f '$SELECTIONS_DIR/config.env' ]]" "Case 4a: dry-run writes no config.env"

# ─── Case 5: a path with a space round-trips through the %q quoting ──────────
SELECTIONS_DIR="$SANDBOX/c5"; seed_params "$SELECTIONS_DIR" "$SANDBOX/c5/my code"
CODE_DIR=""; persist_code_dir
assert_eq "$CODE_DIR" "$SANDBOX/c5/my code" "Case 5a: a spaced path decodes intact"

summary
