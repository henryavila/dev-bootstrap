#!/usr/bin/env bash
# --no-mesh must still wire p10k (git status, dir, host) without ~/.zshrc.local.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

PROMPT="$WS/topics/shell-terminal/templates/zsh/zshrc.d-90-prompt.sh"
ZSHRC="$WS/topics/shell-terminal/templates/zsh/zshrc.template"
UX="$WS/topics/shell-terminal/templates/cli-tools/zshrc.d-20-terminal-ux.sh.template"

assert_file_exists "$PROMPT" "zshrc.d-90-prompt.sh is shipped in shell-terminal/zsh templates"
assert_file_contains "$PROMPT" 'powerlevel10k.zsh-theme' \
    "90-prompt.sh sources the mesh-managed p10k theme"
assert_file_contains "$PROMPT" '.p10k.zsh' \
    "90-prompt.sh sources the shipped p10k config (git-aware lean)"
assert_file_contains "$PROMPT" 'fzf-tab.plugin.zsh' \
    "90-prompt.sh sources fzf-tab without zinit/identity"
assert_file_contains "$PROMPT" 'zsh-autosuggestions' \
    "90-prompt.sh sources zsh-autosuggestions"
assert_file_contains "$PROMPT" 'zsh-syntax-highlighting' \
    "90-prompt.sh sources zsh-syntax-highlighting last"

# deploy auto-map: zshrc.d-90-prompt.sh → ~/.zshrc.d/90-prompt.sh
assert_pattern_present "$WS/scripts/lib/deploy.sh" 'zshrc\.d-\*\.sh' \
    "deploy auto-map still routes zshrc.d-*.sh into ~/.zshrc.d/"

assert_pattern_present "$ZSHRC" 'zshrc\.d/\*\.zsh' \
    "zshrc.template sources shell-bootstrap *.zsh fragments (auto-update, mesh-guard)"
assert_file_contains "$UX" '90-prompt.sh' \
    "cli-tools zsh fragment points p10k at 90-prompt.sh, not identity zshrc.local"

STARSHIP="$WS/topics/shell-terminal/wsl/install-starship.sh"
assert_file_exists "$STARSHIP" "install-starship.sh exists"
assert_pattern_present "$STARSHIP" 'bin-dir' \
    "starship installer uses --bin-dir (no sudo /usr/local/bin hang on WSL pts)"

if grep -nE 'zshrc\.local via zinit' "$UX" >/dev/null 2>&1; then
    fail "20-terminal-ux must not claim p10k is loaded only from identity zshrc.local"
else
    pass "20-terminal-ux does not gate p10k on identity zshrc.local"
fi

summary
