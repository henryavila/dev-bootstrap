#!/usr/bin/env bash
# CP4 C-F-004 regression: shell-bootstrap.sh respects user's existing
# git core.excludesfile + merges gitignore_global content via managed_block
# instead of overwriting.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
SHELL_TOPIC="$WS/topics/shell-terminal"
SCRIPT="$SHELL_TOPIC/shell-bootstrap.sh"
[[ -f "$SCRIPT" ]] || { echo "missing $SCRIPT" >&2; exit 2; }

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected: '$expected', got: '$actual')" >&2; fi
}

require() {
    local name="$1" cond="$2"
    if eval "$cond"; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name" >&2; fi
}

# Run install() / check() / rollback() in isolation: fresh HOME + private
# git config under each scenario. warn() is invoked inside install() on
# missing hook src — define a stub so unset references don't trip set -u.
warn() { echo "warn: $*" >&2; }

scenario() {
    local label="$1" tmp scratch_gitconfig
    echo >&2
    echo "=== $label ===" >&2
    tmp=$(mktemp -d)
    HOME="$tmp" git config --global --unset-all core.excludesfile 2>/dev/null || true
    # Override GIT_CONFIG_GLOBAL to point at a scratch file so we never touch
    # the real ~/.gitconfig.
    scratch_gitconfig="$tmp/.gitconfig"
    : > "$scratch_gitconfig"
    echo "$tmp|$scratch_gitconfig"
}

# Source the script's functions in a subshell with controlled env.
run_install() {
    local tmp="$1" git_cfg="$2" pre_excludesfile="$3"
    (
        export HOME="$tmp"
        export GIT_CONFIG_GLOBAL="$git_cfg"
        export MESH_WORKSTATION_DIR="$WS"
        if [[ -n "$pre_excludesfile" ]]; then
            git config --global core.excludesfile "$pre_excludesfile"
        fi
        # Ensure required fixtures exist without mutating source files.
        for shellfile in auto-update.zsh mesh-guard.zsh gitignore_global; do
            [[ -f "$SHELL_TOPIC/shell-files/$shellfile" ]] || {
                echo "missing fixture: $SHELL_TOPIC/shell-files/$shellfile" >&2
                return 2
            }
        done
        # shellcheck disable=SC1090
        . "$SCRIPT"
        install
    )
}

# ─── Scenario 1: fresh install (no core.excludesfile, no ~/.gitignore_global)
out=$(scenario "S1: fresh install (no prior config)")
TMP="${out%%|*}"; GITCFG="${out##*|}"
run_install "$TMP" "$GITCFG" "" >/dev/null 2>&1
# After install: default file should exist + carry the managed_block
require "S1: ~/.gitignore_global was created" "[[ -f '$TMP/.gitignore_global' ]]"
require "S1: file contains managed_block markers" \
    "grep -q 'BEGIN mesh-managed: gitignore_global' '$TMP/.gitignore_global'"
# core.excludesfile should be registered to our default
val=$(GIT_CONFIG_GLOBAL="$GITCFG" git config --global --get core.excludesfile 2>/dev/null || true)
assert "S1: core.excludesfile set to default" "$TMP/.gitignore_global" "$val"
rm -rf "$TMP"

# ─── Scenario 2: user has custom core.excludesfile pointing elsewhere
out=$(scenario "S2: custom excludesfile path is respected")
TMP="${out%%|*}"; GITCFG="${out##*|}"
USER_PATH="$TMP/.config/git/ignore"
mkdir -p "$(dirname "$USER_PATH")"
printf '# my custom rules\n*.swp\n*.log\n' > "$USER_PATH"
run_install "$TMP" "$GITCFG" "$USER_PATH" >/dev/null 2>&1
# core.excludesfile must stay pointing at the user path (NOT rewritten)
val=$(GIT_CONFIG_GLOBAL="$GITCFG" git config --global --get core.excludesfile 2>/dev/null || true)
assert "S2: core.excludesfile preserved" "$USER_PATH" "$val"
# Default file must NOT be created
require "S2: default ~/.gitignore_global NOT created" "[[ ! -f '$TMP/.gitignore_global' ]]"
# User content is preserved AND our block was appended
require "S2: user content preserved" "grep -q '^\*.swp$' '$USER_PATH'"
require "S2: managed_block appended to user file" \
    "grep -q 'BEGIN mesh-managed: gitignore_global' '$USER_PATH'"
rm -rf "$TMP"

# ─── Scenario 3: re-install is idempotent
out=$(scenario "S3: re-install idempotent (no churn)")
TMP="${out%%|*}"; GITCFG="${out##*|}"
USER_PATH="$TMP/.config/git/ignore"
mkdir -p "$(dirname "$USER_PATH")"
printf 'before-our-block\n' > "$USER_PATH"
run_install "$TMP" "$GITCFG" "$USER_PATH" >/dev/null 2>&1
sum1=$(md5 -q "$USER_PATH" 2>/dev/null || md5sum "$USER_PATH" | awk '{print $1}')
run_install "$TMP" "$GITCFG" "$USER_PATH" >/dev/null 2>&1
sum2=$(md5 -q "$USER_PATH" 2>/dev/null || md5sum "$USER_PATH" | awk '{print $1}')
assert "S3: byte-identical after re-install" "$sum1" "$sum2"
rm -rf "$TMP"

# ─── Scenario 4: rollback strips block but preserves user content
out=$(scenario "S4: rollback removes managed_block, preserves user content")
TMP="${out%%|*}"; GITCFG="${out##*|}"
USER_PATH="$TMP/.config/git/ignore"
mkdir -p "$(dirname "$USER_PATH")"
printf 'user-line-1\nuser-line-2\n' > "$USER_PATH"
run_install "$TMP" "$GITCFG" "$USER_PATH" >/dev/null 2>&1
require "S4: pre-rollback block exists" \
    "grep -q 'BEGIN mesh-managed: gitignore_global' '$USER_PATH'"
(
    export HOME="$TMP"
    export GIT_CONFIG_GLOBAL="$GITCFG"
    export MESH_WORKSTATION_DIR="$WS"
    # shellcheck disable=SC1090
    . "$SCRIPT"
    rollback
) >/dev/null 2>&1
require "S4: post-rollback block stripped" \
    "! grep -q 'BEGIN mesh-managed: gitignore_global' '$USER_PATH'"
require "S4: user content preserved through rollback" \
    "grep -q '^user-line-1$' '$USER_PATH' && grep -q '^user-line-2$' '$USER_PATH'"
rm -rf "$TMP"

echo
echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
