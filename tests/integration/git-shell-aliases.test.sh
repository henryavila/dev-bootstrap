#!/usr/bin/env bash
# tests/integration/git-shell-aliases.test.sh — pin 50-git shell aliases.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

BASH_FRAGMENT="$REPO_ROOT/topics/50-git/templates/bashrc.d-50-git.sh"
ZSH_FRAGMENT="$REPO_ROOT/topics/50-git/templates/zshrc.d-50-git.sh"

assert_file_contains "$BASH_FRAGMENT" "alias gps='g push'" "bash 50-git defines gps as git push"
assert_file_contains "$ZSH_FRAGMENT" "alias gps='g push'" "zsh 50-git defines gps as git push"
assert_file_contains "$BASH_FRAGMENT" "__git_complete gps _git_push" "bash completion treats gps as git push"

summary
