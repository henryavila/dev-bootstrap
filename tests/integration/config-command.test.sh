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
printf 'installed\n' >> "$MESH_CONFIG_TEST_INSTALL_LOG"
SH
chmod +x "$ID/install.sh"

( cd "$ID" && git init -q && git add . )

run_config() {
    HOME="$HOME_FAKE" \
    MESH_CONFIG_IDENTITY_DIR="$ID" \
    MESH_CONFIG_PICKER=bash \
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
    MESH_CONFIG_EDITOR="bash -c 'printf \"# edited\\n\" >> \"\$1\"' mesh-config-editor" \
    bash "$RUNNER" aliases 2>&1
)"
assert_contains "$edit_out" "git diff -- shell/aliases.sh" "changed file prints targeted git diff"
assert_contains "$edit_out" "+# edited" "diff output shows the new line"
assert_eq "$(cat "$INSTALL_LOG")" "installed" "changed file runs identity install"
assert_contains "$(cat "$ID/shell/aliases.sh")" "# edited" "editor modified the source file"

echo
echo "--no-install"
: > "$INSTALL_LOG"
no_install_out="$(
    HOME="$HOME_FAKE" \
    MESH_CONFIG_IDENTITY_DIR="$ID" \
    MESH_CONFIG_TEST_INSTALL_LOG="$INSTALL_LOG" \
    MESH_CONFIG_EDITOR="bash -c 'printf \"# second\\n\" >> \"\$1\"' mesh-config-editor" \
    bash "$RUNNER" zshrc.local --no-install --no-diff 2>&1
)"
assert_contains "$no_install_out" "deploy skipped (--no-install)" "--no-install reports skipped deploy"
assert_eq "$(cat "$INSTALL_LOG")" "" "--no-install does not run install.sh"

echo
echo "dispatcher"
dispatch_out="$(run_config bash "$MESH" config list git)"
assert_contains "$dispatch_out" "Git local config" "bin/mesh dispatches config list"
assert_file_contains "$REPO_ROOT/topics/shell-terminal/templates/zsh/zsh-site-functions/_mesh" \
    "config:edit personal config" "zsh completion advertises mesh config"

echo
summary
