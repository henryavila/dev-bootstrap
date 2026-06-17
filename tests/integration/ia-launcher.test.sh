#!/usr/bin/env bash
# tests/integration/ia-launcher.test.sh
#
# Contract suite for `mesh ia` P0 — the disk project launcher with herdr handoff
# (initiative mesh-ia-launcher).
#
# Covers the two source-only libs against fakes (no real herdr, no real repos):
#   • scripts/lib/ia-discover.sh — multi-root disk discovery + substring match,
#     driven against a fake roots tree;
#   • scripts/lib/ia-herdr.sh    — focus-or-create routing, driven against a
#     stub `herdr` on PATH that records its args and emits canned JSON (real jq).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$SELF_DIR/../lib/assert.sh"
# shellcheck source=../../scripts/lib/log.sh
source "$REPO_ROOT/scripts/lib/log.sh"
# shellcheck source=../../scripts/lib/ia-discover.sh
source "$REPO_ROOT/scripts/lib/ia-discover.sh"
# shellcheck source=../../scripts/lib/ia-herdr.sh
source "$REPO_ROOT/scripts/lib/ia-herdr.sh"
# shellcheck source=../../scripts/lib/ia-agent.sh
source "$REPO_ROOT/scripts/lib/ia-agent.sh"
RUNNER="$REPO_ROOT/scripts/runners/ia.sh"

SANDBOX="$(mktemp -d -t mesh-ia.XXXXXX)"
trap '[[ -d "$SANDBOX" ]] && rm -rf "$SANDBOX"' EXIT

# ── Discovery fixture ────────────────────────────────────────────────────────
# root1: two git repos (dir .git) + one plain dir (no .git, must be ignored)
# root2: one git repo + a mixed-case repo (substring match must be case-insens.)
#        + a repo whose .git is a FILE (gitfile — submodule/worktree, must count)
R1="$SANDBOX/root1"; R2="$SANDBOX/root2"
mkdir -p "$R1/repoA/.git" "$R1/repoB/.git" "$R1/plaindir/src" \
         "$R1/atomic-skills/.git" \
         "$R2/repoC/.git" "$R2/MyApp/.git" "$R2/linked"
echo "gitdir: /elsewhere" > "$R2/linked/.git"   # gitfile, not a dir

echo "── ia-discover ──"
CAT="$(IA_ROOTS="$R1:$R2" ia_discover)"
assert_contains "$CAT" $'repoA\t'"$R1/repoA" "discovers repoA in root1"
assert_contains "$CAT" $'repoB\t'"$R1/repoB" "discovers repoB in root1"
assert_contains "$CAT" $'repoC\t'"$R2/repoC" "discovers repoC in root2"
assert_contains "$CAT" $'MyApp\t'"$R2/MyApp" "discovers MyApp in root2"
assert_contains "$CAT" $'linked\t'"$R2/linked" "counts a gitfile (.git as file)"
assert_not_contains "$CAT" "plaindir" "ignores a non-git dir"

# Missing root contributes nothing, no error.
assert_exit_code 0 'IA_ROOTS="$SANDBOX/nope:$R1" ia_discover' "missing root is not an error"
MISS="$(IA_ROOTS="$SANDBOX/nope:$R1" ia_discover)"
assert_contains "$MISS" "repoA" "still discovers from the existing root"
assert_not_contains "$MISS" "$SANDBOX/nope" "missing root yields no rows"

echo "── ia-roots / defaults ──"
# `~` expansion + `:`/newline split.
ROOTS_OUT="$(IA_ROOTS="~/foo:~/bar" ia_roots)"
assert_contains "$ROOTS_OUT" "$HOME/foo" "expands ~ in IA_ROOTS"
assert_contains "$ROOTS_OUT" "$HOME/bar" "splits IA_ROOTS on :"
# Default roots always include \$HOME as a root.
DEF="$(unset IA_ROOTS; ia_roots)"
assert_contains "$DEF" "$HOME" "default roots include \$HOME"

echo "── ia-match (substring, case-insensitive) ──"
M_APP="$(IA_ROOTS="$R1:$R2" ia_match app)"
assert_contains "$M_APP" "MyApp" "matches 'app' against 'MyApp' (case-insensitive, mid-string)"
assert_not_contains "$M_APP" "repoA" "does not match unrelated repos"
M_REPO="$(IA_ROOTS="$R1:$R2" ia_match repo)"
assert_contains "$M_REPO" "repoA" "'repo' matches repoA"
assert_contains "$M_REPO" "repoC" "'repo' matches repoC"
assert_not_contains "$M_REPO" "MyApp" "'repo' does not match MyApp"
# Empty term → everything.
assert_eq "$(IA_ROOTS="$R1:$R2" ia_match | wc -l | tr -d ' ')" \
          "$(IA_ROOTS="$R1:$R2" ia_discover | wc -l | tr -d ' ')" \
          "empty term returns the full catalogue"

# ── herdr handoff (stub on PATH, real jq) ────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
    echo "── ia-herdr: SKIPPED (jq absent) ──"
else
    echo "── ia-herdr: focus-or-create ──"
    BIN="$SANDBOX/bin"; mkdir -p "$BIN"
    export HERDR_LOG="$SANDBOX/herdr.log"; : > "$HERDR_LOG"
    cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$HERDR_LOG"
case "$1 $2" in
  "workspace list")
    printf '%s' '{"result":{"workspaces":[{"label":"mesh-identity","workspace_id":"w123","agent_status":"blocked"},{"label":"atomic-skills","workspace_id":"w456","agent_status":"done"}]}}' ;;
  "workspace create")
    printf '%s' '{"result":{"root_pane":{"pane_id":"wNEW-1"},"workspace":{"workspace_id":"wNEW"}}}' ;;
  "pane list")
    printf '%s' '{"result":{"panes":[{"cwd":"/home/henry/arch/.worktrees/feature"},{"cwd":"/other"}]}}' ;;
  "tab list")
    printf '%s' '{"result":{"tabs":[{"tab_id":"w123:1","label":"Design Brief","agent_status":"idle"},{"tab_id":"w123:2","label":"Dashboard","agent_status":"working"}]}}' ;;
  *) : ;;
esac
STUB
    chmod +x "$BIN/herdr"
    OLD_PATH="$PATH"; export PATH="$BIN:$PATH"

    assert_true 'ia_herdr_ready' "ia_herdr_ready true when herdr+jq present"
    assert_eq "$(ia_herdr_workspace_id mesh-identity)" "w123" "resolves workspace_id by label"
    assert_eq "$(ia_herdr_workspace_id ghost)" "" "empty for an unopened label"
    assert_eq "$(ia_herdr_workspace_cwd w123)" "/home/henry/arch/.worktrees/feature" "workspace cwd = first pane cwd"
    assert_eq "$(ia_herdr_tabs w123 | wc -l | tr -d ' ')" "2" "lists a workspace's tabs"
    assert_contains "$(ia_herdr_tabs w123)" "$(printf 'w123:2\tDashboard\tworking')" "tab row = tab_id+label+status"
    : > "$HERDR_LOG"
    ia_herdr_focus_tab w123 w123:2 >/dev/null 2>&1
    FT="$(cat "$HERDR_LOG")"
    assert_contains "$FT" "workspace focus w123" "focus_tab brings the workspace to front"
    assert_contains "$FT" "tab focus w123:2" "focus_tab focuses the exact tab"

    # Case 1: label already open → FOCUS, never create.
    : > "$HERDR_LOG"
    ia_herdr_open "mesh-identity" "/whatever" "claude" >/dev/null 2>&1
    LOG1="$(cat "$HERDR_LOG")"
    assert_contains "$LOG1" "workspace focus w123" "open project → workspace focus <id>"
    assert_not_contains "$LOG1" "workspace create" "open project → no create"

    # Case 2: not open → CREATE at path + run agent in the new root pane.
    : > "$HERDR_LOG"
    ia_herdr_open "newproj" "/abs/path" "claude --dangerously-skip-permissions" >/dev/null 2>&1
    LOG2="$(cat "$HERDR_LOG")"
    assert_contains "$LOG2" "workspace create --cwd /abs/path --label newproj --focus" "new project → create with cwd+label"
    assert_contains "$LOG2" "pane run wNEW-1 claude --dangerously-skip-permissions" "new project → run agent in new root pane"

    export PATH="$OLD_PATH"
fi

# ── herdr readiness guard (herdr absent) ─────────────────────────────────────
echo "── ia-herdr: readiness guard ──"
assert_false 'PATH="/nonexistent" ia_herdr_ready' "ia_herdr_ready false when herdr missing"

# ── ia-agent: resolution + per-project memory ────────────────────────────────
echo "── ia-agent ──"
export XDG_STATE_HOME="$SANDBOX/state"
assert_eq "$(ia_agent_cmd claude)" "claude" "bare agent cmd when no flags env"
assert_eq "$(MESH_IA_FLAGS_CLAUDE='--dangerously-skip-permissions' ia_agent_cmd claude)" \
          "claude --dangerously-skip-permissions" "flags env appended to agent cmd"
assert_eq "$(ia_agent_resolve repoA 'codex')" "codex" "override wins in resolve"
assert_eq "$(MESH_IA_AGENT=gemini ia_agent_resolve repoA '')" "gemini" "MESH_IA_AGENT default when no override/memory"
assert_eq "$(ia_agent_resolve repoA '')" "claude" "falls back to 'claude' with nothing set"
ia_agent_set repoA codex
assert_eq "$(ia_agent_get repoA)" "codex" "remembers agent per project"
assert_eq "$(ia_agent_resolve repoA '')" "codex" "remembered agent wins over MESH_IA_AGENT default"
ia_agent_set repoA claude   # idempotent upsert (not append)
assert_eq "$(ia_agent_get repoA)" "claude" "upsert replaces, not appends"
assert_eq "$(grep -c '^repoA=' "$(ia_agent_state_file)")" "1" "only one line per project"
unset XDG_STATE_HOME

# ── runner end-to-end (stub herdr, isolated $HOME) ───────────────────────────
if command -v jq >/dev/null 2>&1; then
    echo "── runner: mesh ia ──"
    RBIN="$SANDBOX/rbin"; mkdir -p "$RBIN"
    RHOME="$SANDBOX/rhome"; mkdir -p "$RHOME"   # no ~/.config/mesh/config.env here
    export HERDR_LOG="$SANDBOX/runner-herdr.log"
    cat > "$RBIN/herdr" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$HERDR_LOG"
case "$1 $2" in
  "workspace list")   printf '%s' '{"result":{"workspaces":[{"label":"atomic-skills","workspace_id":"w456","agent_status":"done"},{"label":"ghostws","workspace_id":"w999","agent_status":"working"},{"label":"multi","workspace_id":"w777","agent_status":"working"}]}}' ;;
  "workspace create") printf '%s' '{"result":{"root_pane":{"pane_id":"wNEW-1"},"workspace":{"workspace_id":"wNEW"}}}' ;;
  "pane list")        printf '%s' '{"result":{"panes":[{"cwd":"/srv/ghost/work"}]}}' ;;
  "tab list")
    # $4 = the --workspace id; only `multi` (w777) has several tabs.
    if [[ "$4" == w777 ]]; then
      printf '%s' '{"result":{"tabs":[{"tab_id":"w777:1","label":"Alpha","agent_status":"idle"},{"tab_id":"w777:2","label":"Beta","agent_status":"working"},{"tab_id":"w777:3","label":"Gamma","agent_status":"blocked"}]}}'
    else
      printf '%s' '{"result":{"tabs":[{"tab_id":"'"$4"':1","label":"main","agent_status":"done"}]}}'
    fi ;;
  *) : ;;
esac
STUB
    chmod +x "$RBIN/herdr"

    run_ia() {  # run the real runner in an isolated env
        HOME="$RHOME" XDG_STATE_HOME="$SANDBOX/rstate" IA_ROOTS="$R1:$R2" \
        MESH_IA_PICKER=bash PATH="$RBIN:$PATH" \
        MESH_IA_AGENT=claude MESH_IA_FLAGS_CLAUDE='--dangerously-skip-permissions' \
            bash "$RUNNER" "$@"
    }

    # --list: disk catalogue only, never touches herdr.
    : > "$HERDR_LOG"
    LIST_OUT="$(run_ia --list 2>/dev/null)"
    assert_contains "$LIST_OUT" "repoA" "--list prints the disk catalogue"
    assert_eq "$(cat "$HERDR_LOG")" "" "--list never touches herdr"

    # --candidates: the MERGED, deduped set (open workspaces + disk repos).
    CANDS="$(run_ia --candidates 2>/dev/null)"
    assert_eq "$(printf '%s\n' "$CANDS" | awk -F'\t' '$1=="atomic-skills"' | grep -c .)" "1" \
        "open + disk repo of the same name dedupe to ONE row"
    assert_contains "$CANDS" "$(printf 'atomic-skills\t%s\tw456\tdone' "$R1/atomic-skills")" \
        "deduped row carries the disk path + wsid + status"
    assert_contains "$CANDS" "$(printf 'ghostws\t/srv/ghost/work\tw999\tworking')" \
        "open-only workspace shows its pane cwd (which project)"
    assert_contains "$CANDS" "$(printf 'repoB\t%s\t\t' "$R1/repoB")" \
        "closed repo: path with empty wsid"

    # Tabs: a multi-tab workspace keeps its bare row AND gains one row per tab.
    assert_eq "$(printf '%s\n' "$CANDS" | awk -F'\t' '$1=="multi"' | grep -c .)" "1" \
        "multi-tab workspace still has exactly one bare workspace row"
    assert_contains "$CANDS" "$(printf 'multi › Beta\t/srv/ghost/work\tw777\tworking\tw777:2')" \
        "each tab becomes a searchable row carrying its tab_id"
    # A single-tab workspace is NOT expanded.
    assert_eq "$(printf '%s\n' "$CANDS" | awk -F'\t' '$1 ~ /^atomic-skills › /' | grep -c .)" "0" \
        "single-tab workspace is not expanded into tab rows"

    # Fast path: a unique tab-name term jumps straight to that tab.
    : > "$HERDR_LOG"
    run_ia Gamma >/dev/null 2>&1
    RLOGT="$(cat "$HERDR_LOG")"
    assert_contains "$RLOGT" "workspace focus w777" "tab term brings the workspace to front"
    assert_contains "$RLOGT" "tab focus w777:3" "tab term focuses the exact tab"

    # Fast path: unique closed repo → create + launch resolved agent.
    : > "$HERDR_LOG"
    run_ia repoB >/dev/null 2>&1
    RLOG="$(cat "$HERDR_LOG")"
    assert_contains "$RLOG" "workspace create --cwd $R1/repoB --label repoB --focus" "term→single repo creates at its path"
    assert_contains "$RLOG" "pane run wNEW-1 claude --dangerously-skip-permissions" "launches the identity-default agent+flags"

    # Fast path: term matching an open workspace that is also a disk repo → focus.
    : > "$HERDR_LOG"
    run_ia atomic-skills >/dev/null 2>&1
    RLOG2="$(cat "$HERDR_LOG")"
    assert_contains "$RLOG2" "workspace focus w456" "open+disk term → focus"
    assert_not_contains "$RLOG2" "workspace create" "open+disk term → no create"

    # Fast path: term matching an OPEN-ONLY workspace (not on disk) → focus.
    : > "$HERDR_LOG"
    run_ia ghostws >/dev/null 2>&1
    assert_contains "$(cat "$HERDR_LOG")" "workspace focus w999" "open-only term → focus (matched by label, not disk)"

    # --agent override is remembered for the project.
    : > "$HERDR_LOG"
    run_ia repoA --agent codex >/dev/null 2>&1
    assert_eq "$(grep '^repoA=' "$SANDBOX/rstate/mesh/ia-agents.env" 2>/dev/null)" "repoA=codex" "--agent override is remembered"

    # Unknown term → exit 1; a read-only list is fine, but NEVER a mutation.
    : > "$HERDR_LOG"
    assert_exit_code 1 'run_ia no-such-repo-xyz' "unknown term exits 1"
    NLOG="$(cat "$HERDR_LOG")"
    assert_not_contains "$NLOG" "workspace create" "unknown term never creates"
    assert_not_contains "$NLOG" "workspace focus" "unknown term never focuses"
else
    echo "── runner: SKIPPED (jq absent) ──"
fi

summary
