#!/usr/bin/env bash
# tests/integration/ia-pinned.test.sh
#
# Contract suite for `mesh ia` pinned-projects layer (ad-hoc mesh-ia-pinned).
#
# Covers the source-only reader ia-pinned.sh (manifest parse, alternate-path
# pick, skip-missing, ~ expansion, non-git allowed, comments/blanks) and the
# runner verbs add/remove/list + the merged ia_catalogue (pinned-wins dedup),
# driven against a sandbox (no real herdr, no real repos).
#
# NOTE: assert_exit_code / assert_true / assert_false take the COMMAND as their
# trailing args (joined by $*) and the message via the ASSERT_MSG env var — a
# trailing "msg" string would be appended to the command and become extra args
# to the verb under test. So set ASSERT_MSG, never pass a positional message.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/log.sh
source "$REPO_ROOT/scripts/lib/log.sh"
# shellcheck source=../../scripts/lib/ia-discover.sh
source "$REPO_ROOT/scripts/lib/ia-discover.sh"
# shellcheck source=../../scripts/lib/ia-pinned.sh
source "$REPO_ROOT/scripts/lib/ia-pinned.sh"
# assert.sh LAST, on purpose: log.sh defines a non-counting fail()/ok() that
# would otherwise SHADOW assert.sh's counting pass()/fail() — masking failures.
# shellcheck source=../lib/assert.sh
source "$SELF_DIR/../lib/assert.sh"
RUNNER="$REPO_ROOT/scripts/runners/ia.sh"

SANDBOX="$(mktemp -d -t mesh-ia-pin.XXXXXX)"
trap '[[ -d "$SANDBOX" ]] && rm -rf "$SANDBOX"' EXIT
HOME_SANDBOX="$SANDBOX/home"; mkdir -p "$HOME_SANDBOX"
PINS="$SANDBOX/pins.list"

# Isolate the runner from the real ~/.config/mesh/config.env and point every
# path at the sandbox. Verbs only touch $MESH_IA_PINNED; --list also takes IA_ROOTS.
run_verb() { HOME="$HOME_SANDBOX" MESH_IA_PINNED="$PINS" MESH_IDENTITY_DIR="$SANDBOX" bash "$RUNNER" "$@"; }
run_verb_prompt() {
    local input="$1"; shift
    printf '%b' "$input" > "$SANDBOX/prompt.in"
    HOME="$HOME_SANDBOX" \
        MESH_IA_PINNED="$PINS" \
        MESH_IDENTITY_DIR="$SANDBOX" \
        MESH_PROMPT_IN="$SANDBOX/prompt.in" \
        MESH_PROMPT_OUT="$SANDBOX/prompt.out" \
        MESH_PROMPT_TUI=off \
        bash "$RUNNER" "$@"
}

# ── ia_pinned: parse, alternates, skip-missing, ~, comments, non-git ─────────
echo "── ia_pinned ──"
mkdir -p "$SANDBOX/exists" "$SANDBOX/notgit" "$HOME_SANDBOX/sub"
cat > "$PINS" <<EOF
# a comment line
mesh-id|$SANDBOX/exists

proj|/nope/A:/nope/B:$SANDBOX/exists   # inline comment + alts; 3rd wins
gone|/nope/X:/nope/Y                     # all alts missing → skipped
homeproj|~/sub                           # ~ expansion
EOF
OUT="$(HOME="$HOME_SANDBOX" MESH_IA_PINNED="$PINS" ia_pinned)"
assert_contains   "$OUT" $'mesh-id\t'"$SANDBOX/exists" "emits a plain pinned entry"
assert_contains   "$OUT" $'proj\t'"$SANDBOX/exists"     "picks the FIRST existing alternate path"
assert_not_contains "$OUT" "gone"                       "skips an entry whose alts are all missing"
assert_contains   "$OUT" $'homeproj\t'"$HOME_SANDBOX/sub" "expands ~ to \$HOME"
assert_not_contains "$OUT" "a comment line"             "ignores full-line comments"
# Missing manifest is a no-op (never an error).
ASSERT_MSG="missing manifest is not an error" assert_exit_code 0 'MESH_IA_PINNED="'"$SANDBOX"'/absent.list" ia_pinned'
# Non-git dir is allowed (pinned overrides ia_discover's .git gate).
NGFILE="$SANDBOX/ng.list"; printf 'notes|%s\n' "$SANDBOX/notgit" > "$NGFILE"
assert_contains "$(MESH_IA_PINNED="$NGFILE" ia_pinned)" $'notes\t'"$SANDBOX/notgit" "pins a non-git dir"

# ── ia_catalogue (via --list): merge + pinned-wins + substring ───────────────
echo "── ia_catalogue (via --list) ──"
# Discovery fixture: root with two git repos, one named 'collide'.
R1="$SANDBOX/root1"; mkdir -p "$R1/collide/.git" "$R1/other/.git"
# Pin 'collide' to a DIFFERENT path → pin must win on the name collision.
mkdir -p "$SANDBOX/pinned-collide"
cat > "$PINS" <<EOF
collide|$SANDBOX/pinned-collide
onlypinned|$SANDBOX/exists
EOF
LIST_OUT="$(HOME="$HOME_SANDBOX" MESH_IA_PINNED="$PINS" MESH_IDENTITY_DIR="$SANDBOX" IA_ROOTS="$R1" bash "$RUNNER" --list)"
# Exactly ONE collide row, and it carries the PINNED path (not the discovered one).
COLLIDE_ROWS="$(printf '%s\n' "$LIST_OUT" | awk -F'\t' '$1=="collide"' | grep -c . || true)"
assert_eq "$COLLIDE_ROWS" "1" "colliding name appears exactly once (pinned wins)"
assert_contains "$LIST_OUT" $'collide\t'"$SANDBOX/pinned-collide" "collide row uses the PINNED path"
assert_not_contains "$LIST_OUT" $'collide\t'"$R1/collide"         "collide row drops the discovered path"
assert_contains "$LIST_OUT" "other"        "discovered-only repo still listed"
assert_contains "$LIST_OUT" "onlypinned"   "pinned-only entry still listed"
# Substring filter reaches a pinned entry.
SUB="$(HOME="$HOME_SANDBOX" MESH_IA_PINNED="$PINS" MESH_IDENTITY_DIR="$SANDBOX" IA_ROOTS="$R1" bash "$RUNNER" --list onlypinned)"
assert_contains "$SUB" "onlypinned"    "substring filter matches a pinned entry"
assert_not_contains "$SUB" "other"      "substring filter excludes non-matching repos"

# ── mesh ia add: create, idempotent update, default name, missing reject ────
echo "── mesh ia add ──"
rm -f "$PINS"
mkdir -p "$SANDBOX/projA"
ASSERT_MSG="add succeeds for an existing dir" assert_exit_code 0 'run_verb add "'"$SANDBOX"'/projA"'
assert_file_exists "$PINS"                                  "add creates the manifest if absent"
assert_file_contains "$PINS" '^projA|'                      "add writes a 'name|path' line"
assert_file_contains "$PINS" $'projA|'"$SANDBOX"'/projA'    "add resolves to an absolute path"
# Idempotent upsert: re-adding the SAME name with a different path replaces, not duplicates.
mkdir -p "$SANDBOX/projA2"
ASSERT_MSG="re-add same name updates the path" assert_exit_code 0 'run_verb add "'"$SANDBOX"'/projA2" projA'
DUPS="$(grep -c '^projA|' "$PINS" || true)"
assert_eq "$DUPS" "1"                                       "add does not duplicate the name"
assert_file_contains "$PINS" $'projA|'"$SANDBOX"'/projA2'   "add updated the path in place"
# Default name derived from basename when omitted.
mkdir -p "$SANDBOX/myproj"
ASSERT_MSG="add without name arg succeeds" assert_exit_code 0 'run_verb add "'"$SANDBOX"'/myproj"'
assert_file_contains "$PINS" '^myproj|'                     "add derives name from basename"
# Missing path is rejected (exit 2), manifest unchanged.
SNAP="$(cat "$PINS")"
ASSERT_MSG="add rejects a non-existent path (exit 2)" assert_exit_code 2 'run_verb add "'"$SANDBOX"'/does-not-exist"'
assert_eq "$(cat "$PINS")" "$SNAP"                          "rejected add leaves the manifest unchanged"

# If the pinned manifest lives inside a git identity repo, a successful add must
# not leave the user thinking "saved" means replicated. It prompts to commit and
# push; accepting creates the commit and pushes it to the upstream.
echo "── mesh ia add: git persistence prompt ──"
GITROOT="$SANDBOX/git-identity"
GITROOT_REAL="$(cd "$GITROOT" 2>/dev/null && pwd -P || true)"
REMOTE="$SANDBOX/remote.git"
mkdir -p "$GITROOT/shell" "$SANDBOX/gitproj"
git init -q --bare "$REMOTE"
git -C "$GITROOT" init -q
git -C "$GITROOT" config user.name "Mesh Test"
git -C "$GITROOT" config user.email "mesh@example.test"
git -C "$GITROOT" remote add origin "$REMOTE"
printf '# pins\n' > "$GITROOT/shell/ia-pinned.list"
git -C "$GITROOT" add shell/ia-pinned.list
git -C "$GITROOT" commit -qm "init pins"
git -C "$GITROOT" branch -M main
git -C "$GITROOT" push -q -u origin main
GITROOT_REAL="$(cd "$GITROOT" && pwd -P)"
PINS="$GITROOT/shell/ia-pinned.list"
ADD_PUSH_OUT="$(run_verb_prompt "y\n" add "$SANDBOX/gitproj" gitproj 2>&1)"
assert_contains "$ADD_PUSH_OUT" "Commitar e enviar"          "add asks whether to push the new pin"
assert_contains "$ADD_PUSH_OUT" "pin manifest committed and pushed" "accepted add commits and pushes"
assert_eq "$(git -C "$GITROOT" rev-list --count '@{upstream}..HEAD')" "0" "accepted add leaves no unpushed commit"
ASSERT_MSG="accepted add reaches the remote" assert_true "git -C '$REMOTE' show main:shell/ia-pinned.list | grep -q '^gitproj|'"

# Declining the prompt is allowed, but it must be loud and actionable.
mkdir -p "$SANDBOX/localonly"
ADD_LOCAL_OUT="$(run_verb_prompt "n\n" add "$SANDBOX/localonly" localonly 2>&1)"
assert_contains "$ADD_LOCAL_OUT" "saved only locally"        "declined add warns that the pin is local-only"
assert_contains "$ADD_LOCAL_OUT" "git -C '$GITROOT_REAL' add 'shell/ia-pinned.list'" "declined add prints the exact recovery command"
PINS="$SANDBOX/pins.list"

# ── mesh ia remove: by name, unknown ────────────────────────────────────────
echo "── mesh ia remove ──"
ASSERT_MSG="remove an existing pin succeeds" assert_exit_code 0 'run_verb remove myproj'
ASSERT_MSG="remove drops the named line" assert_false 'grep -q "^myproj|" "'"$PINS"'"'
assert_file_contains "$PINS" '^projA|'                      "remove leaves other pins intact"
# Unknown name: exit 1, manifest byte-identical before/after.
SNAP2="$(cat "$PINS")"
ASSERT_MSG="remove of unknown name exits 1" assert_exit_code 1 'run_verb remove never-pinned'
assert_eq "$(cat "$PINS")" "$SNAP2"                         "unknown remove leaves the manifest unchanged"

echo "── mesh ia remove: git persistence prompt ──"
GITROOT_RM="$SANDBOX/git-identity-remove"
REMOTE_RM="$SANDBOX/remote-remove.git"
mkdir -p "$GITROOT_RM/shell"
git init -q --bare "$REMOTE_RM"
git -C "$GITROOT_RM" init -q
git -C "$GITROOT_RM" config user.name "Mesh Test"
git -C "$GITROOT_RM" config user.email "mesh@example.test"
git -C "$GITROOT_RM" remote add origin "$REMOTE_RM"
printf 'remove-me|%s\nkeep-me|%s\n' "$SANDBOX/projA" "$SANDBOX/projA2" > "$GITROOT_RM/shell/ia-pinned.list"
git -C "$GITROOT_RM" add shell/ia-pinned.list
git -C "$GITROOT_RM" commit -qm "init remove pins"
git -C "$GITROOT_RM" branch -M main
git -C "$GITROOT_RM" push -q -u origin main
PINS="$GITROOT_RM/shell/ia-pinned.list"
RM_PUSH_OUT="$(run_verb_prompt "y\n" remove remove-me 2>&1)"
assert_contains "$RM_PUSH_OUT" "Commitar e enviar"          "remove asks whether to push the deleted pin"
assert_contains "$RM_PUSH_OUT" "pin manifest committed and pushed" "accepted remove commits and pushes"
assert_eq "$(git -C "$GITROOT_RM" rev-list --count '@{upstream}..HEAD')" "0" "accepted remove leaves no unpushed commit"
ASSERT_MSG="accepted remove reaches the remote" assert_false "git -C '$REMOTE_RM' show main:shell/ia-pinned.list | grep -q '^remove-me|'"
ASSERT_MSG="accepted remove preserves other remote pins" assert_true "git -C '$REMOTE_RM' show main:shell/ia-pinned.list | grep -q '^keep-me|'"
PINS="$SANDBOX/pins.list"

# ── mesh ia list ────────────────────────────────────────────────────────────
echo "── mesh ia list ──"
LST_OUT="$(run_verb list)"
assert_contains "$LST_OUT" "projA"  "list shows the pinned project resolvable on this host"

summary
