#!/usr/bin/env bash
# tests/integration/config-command.test.sh
#
# Contract suite for `mesh config`: the deploy.map-backed personal config editor.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
RUNNER="$REPO_ROOT/scripts/runners/config.sh"
MESH="$REPO_ROOT/bin/mesh"
# shellcheck disable=SC1091
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-config.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

ID="$SANDBOX/identity"
HOME_FAKE="$SANDBOX/home"
mkdir -p "$ID/shell" "$ID/git" "$ID/claude/manifest" "$HOME_FAKE"

cat > "$ID/deploy.map" <<'MAP'
shell/aliases.sh             | ~/.bashrc.d/99-personal-aliases.sh
shell/aliases.sh             | ~/.zshrc.d/99-personal-aliases.sh
shell/zshrc.local            | ~/.zshrc.local
git/gitconfig.local          | ~/.gitconfig.local
claude/manifest/shared.json  | ~/.claude/manifest/shared.json
MAP

printf "alias ll='ls -la'\n" > "$ID/shell/aliases.sh"
printf "# zsh\n" > "$ID/shell/zshrc.local"
printf "[user]\n\tname = Test\n" > "$ID/git/gitconfig.local"
printf "{}\n" > "$ID/claude/manifest/shared.json"
cat > "$ID/install.sh" <<'SH'
#!/usr/bin/env bash
printf 'NOISY stdout from install\n'
printf 'NOISY stderr from install\n' >&2
printf 'installed\n' >> "$MESH_CONFIG_TEST_INSTALL_LOG"
SH
chmod +x "$ID/install.sh"

( cd "$ID" \
    && git init -q \
    && git config user.name "Mesh Config Test" \
    && git config user.email "mesh-config@example.invalid" \
    && git add . \
    && git commit -q -m "initial identity config" )

printf 'n\n' > "$SANDBOX/prompt.in"
run_config() {
    HOME="$HOME_FAKE" \
    MESH_CONFIG_IDENTITY_DIR="$ID" \
    MESH_CONFIG_PICKER=bash \
    MESH_PROMPT_TUI=off \
    MESH_PROMPT_IN="$SANDBOX/prompt.in" \
    "$@"
}

echo "list"
list_out="$(run_config bash "$RUNNER" list)"
assert_contains "$list_out" "Personal aliases" "list labels aliases"
assert_contains "$list_out" "shell/aliases.sh" "list includes source path"
assert_contains "$list_out" ".bashrc.d/99-personal-aliases.sh" "list includes bash destination"
assert_contains "$list_out" ".zshrc.d/99-personal-aliases.sh" "duplicate source destinations are collapsed"

echo
echo "edit -> diff -> install"
INSTALL_LOG="$SANDBOX/install.log"
: > "$INSTALL_LOG"
edit_out="$(
    HOME="$HOME_FAKE" \
    MESH_CONFIG_IDENTITY_DIR="$ID" \
    MESH_CONFIG_TEST_INSTALL_LOG="$INSTALL_LOG" \
    MESH_PROMPT_TUI=off \
    MESH_PROMPT_IN="$SANDBOX/prompt.in" \
    MESH_CONFIG_EDITOR="bash -c 'printf \"# edited\\n\" >> \"\$1\"' mesh-config-editor" \
    bash "$RUNNER" aliases 2>&1
)"
assert_contains "$edit_out" "git diff -- shell/aliases.sh" "changed file prints targeted git diff"
assert_contains "$edit_out" "+# edited" "diff output shows the new line"
assert_not_contains "$edit_out" "NOISY stdout" "successful install stdout is suppressed"
assert_not_contains "$edit_out" "NOISY stderr" "successful install stderr is suppressed"
assert_contains "$edit_out" "not committed or pushed" "non-tty run reports local-only save state"
assert_eq "$(cat "$INSTALL_LOG")" "installed" "changed file runs identity install"
assert_contains "$(cat "$ID/shell/aliases.sh")" "# edited" "editor modified the source file"

echo
echo "--no-install"
: > "$INSTALL_LOG"
no_install_out="$(
    HOME="$HOME_FAKE" \
    MESH_CONFIG_IDENTITY_DIR="$ID" \
    MESH_CONFIG_TEST_INSTALL_LOG="$INSTALL_LOG" \
    MESH_PROMPT_TUI=off \
    MESH_PROMPT_IN="$SANDBOX/prompt.in" \
    MESH_CONFIG_EDITOR="bash -c 'printf \"# second\\n\" >> \"\$1\"' mesh-config-editor" \
    bash "$RUNNER" zshrc.local --no-install --no-diff 2>&1
)"
assert_contains "$no_install_out" "deploy skipped (--no-install)" "--no-install reports skipped deploy"
assert_eq "$(cat "$INSTALL_LOG")" "" "--no-install does not run install.sh"

echo
echo "confirm commit + push"
ID_COMMIT="$SANDBOX/identity-commit"
REMOTE="$SANDBOX/identity-remote.git"
HOME_COMMIT="$SANDBOX/home-commit"
mkdir -p "$ID_COMMIT/shell" "$HOME_COMMIT"
cat > "$ID_COMMIT/deploy.map" <<'MAP'
shell/aliases.sh | ~/.zshrc.d/99-personal-aliases.sh
MAP
printf "alias aa='one'\n" > "$ID_COMMIT/shell/aliases.sh"
cat > "$ID_COMMIT/install.sh" <<'SH'
#!/usr/bin/env bash
printf 'commit install noise\n'
printf 'installed\n' >> "$MESH_CONFIG_TEST_INSTALL_LOG"
SH
chmod +x "$ID_COMMIT/install.sh"
git init -q --bare "$REMOTE"
(
    cd "$ID_COMMIT" \
        && git init -q \
        && git config user.name "Mesh Config Test" \
        && git config user.email "mesh-config@example.invalid" \
        && git add . \
        && git commit -q -m "initial identity config" \
        && git branch -M main \
        && git remote add origin "$REMOTE" \
        && git push -q -u origin main
)
COMMIT_LOG="$SANDBOX/commit-install.log"
PROMPT_IN="$SANDBOX/prompt-in"
PROMPT_OUT="$SANDBOX/prompt-out"
: > "$COMMIT_LOG"
printf 'y\n' > "$PROMPT_IN"
commit_out="$(
    HOME="$HOME_COMMIT" \
    MESH_CONFIG_IDENTITY_DIR="$ID_COMMIT" \
    MESH_CONFIG_TEST_INSTALL_LOG="$COMMIT_LOG" \
    MESH_PROMPT_TUI=off \
    MESH_PROMPT_IN="$PROMPT_IN" \
    MESH_PROMPT_OUT="$PROMPT_OUT" \
    MESH_CONFIG_EDITOR="bash -c 'printf \"alias bb=two\\n\" >> \"\$1\"' mesh-config-editor" \
    bash "$RUNNER" aliases --no-diff 2>&1
)"
assert_not_contains "$commit_out" "commit install noise" "confirmed push keeps successful install output quiet"
assert_contains "$(cat "$PROMPT_OUT")" "Commit and push this config change?" "confirmed push asks before committing"
assert_contains "$commit_out" "committed" "confirmed push reports commit"
assert_contains "$commit_out" "pushed" "confirmed push reports push"
assert_eq "$(git -C "$ID_COMMIT" status --short)" "" "confirmed push leaves identity worktree clean"
assert_contains "$(git --git-dir="$REMOTE" log --oneline --all)" "config(identity): update Personal aliases" \
    "confirmed push pushed the config commit to origin"

echo
echo "dispatcher"
dispatch_out="$(run_config bash "$MESH" config list git)"
assert_contains "$dispatch_out" "Git local config" "bin/mesh dispatches config list"
assert_file_contains "$REPO_ROOT/topics/shell-terminal/templates/zsh/zsh-site-functions/_mesh" \
    "config:edit personal config" "zsh completion advertises mesh config"

echo
summary
