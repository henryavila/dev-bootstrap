#!/usr/bin/env bash
# Windows Terminal merge: Catppuccin + NF, WSL as default when WT is still on
# the factory PowerShell profile, never seed an empty profiles.list.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

JQ_FILTER="$WS/topics/shell-terminal/scripts/wt-settings-merge.jq"
FRAG="$WS/topics/shell-terminal/scripts/wt-settings-fragment.json"
SCRIPT="$WS/topics/shell-terminal/scripts/configure-windows-terminal.sh"
FIX="$HERE/fixtures/windows-terminal"

assert_file_exists "$JQ_FILTER" "wt-settings-merge.jq exists"
assert_file_exists "$FRAG" "wt-settings-fragment.json exists"
assert_file_exists "$SCRIPT" "configure-windows-terminal.sh exists"

# Do not write a skeleton settings.json with an empty profile list — WT then
# launches with no Ubuntu profile (or refuses to auto-generate one).
if grep -qE '"list":\s*\[\]' "$SCRIPT"; then
    fail "configure-windows-terminal.sh must not seed settings.json with empty profiles.list"
else
    pass "configure-windows-terminal.sh does not seed an empty profiles.list"
fi
if grep -q 'seeding' "$SCRIPT"; then
    fail "configure-windows-terminal.sh must not seed a missing settings.json"
else
    pass "configure-windows-terminal.sh does not seed a missing settings.json"
fi
assert_file_contains "$SCRIPT" 'wt-settings-merge.jq' \
    "configure-windows-terminal.sh uses the shared jq merge filter"

if ! command -v jq >/dev/null 2>&1; then
    fail "jq is required for the merge tests"
    summary
    exit 1
fi

merge() {
    local src="$1" distro="${2:-Ubuntu-24.04}"
    jq --slurpfile frag "$FRAG" --arg distro "$distro" -f "$JQ_FILTER" "$src"
}

factory="$FIX/factory-settings.json"
assert_file_exists "$factory" "factory WT fixture exists"
out="$(merge "$factory")" || { fail "jq merge failed on factory fixture"; out='{}'; }

assert_eq "$(printf '%s' "$out" | jq -r '.defaultProfile')" \
    "{963ff2f7-6aed-5ce3-9d91-90d99571f53a}" \
    "factory PowerShell default is switched to the Ubuntu WSL profile"
assert_eq "$(printf '%s' "$out" | jq -r '.profiles.list[] | select(.name=="Ubuntu-24.04") | .hidden')" \
    "false" \
    "hidden WSL Ubuntu profile is unhidden"
assert_eq "$(printf '%s' "$out" | jq -r '.profiles.defaults.colorScheme')" \
    "Catppuccin Mocha" \
    "factory defaults pick up Catppuccin Mocha"
assert_eq "$(printf '%s' "$out" | jq -r '.profiles.defaults.font.face')" \
    "CaskaydiaCove Nerd Font" \
    "factory defaults pick up CaskaydiaCove NF"
assert_eq "$(printf '%s' "$out" | jq -r '.schemes[0].name')" \
    "Catppuccin Mocha" \
    "Catppuccin scheme is appended"

already="$FIX/ubuntu-already-default.json"
assert_file_exists "$already" "already-default WT fixture exists"
out2="$(merge "$already")" || { fail "jq merge failed on already-default fixture"; out2='{}'; }
assert_eq "$(printf '%s' "$out2" | jq -r '.defaultProfile')" \
    "{d8e96812-b789-5068-a5ae-10b2fb53e95f}" \
    "existing Ubuntu defaultProfile is left alone"
assert_eq "$(printf '%s' "$out2" | jq -r '.profiles.defaults.font.size')" \
    "15" \
    "user font.size is preserved"
assert_eq "$(printf '%s' "$out2" | jq -r '.profiles.defaults.font.face')" \
    "CaskaydiaCove Nerd Font" \
    "missing font.face is filled from the fragment (deep merge)"
assert_eq "$(printf '%s' "$out2" | jq -r '.profiles.defaults.colorScheme')" \
    "Solarized Dark" \
    "user colorScheme wins over the fragment"

# Both shells must source fzf key-bindings — WT login shell is zsh after chsh,
# but Ubuntu's fzf package only auto-wires bash-completion.
zsh_frag="$WS/topics/shell-terminal/templates/cli-tools/zshrc.d-20-terminal-ux.sh.template"
bash_frag="$WS/topics/shell-terminal/templates/cli-tools/bashrc.d-20-terminal-ux.sh.template"
assert_file_contains "$zsh_frag" 'key-bindings.zsh' \
    "zsh fragment sources fzf key-bindings.zsh"
assert_file_contains "$bash_frag" 'key-bindings.bash' \
    "bash fragment sources fzf key-bindings.bash"
assert_file_contains "$zsh_frag" '/usr/share/doc/fzf/examples/key-bindings.zsh' \
    "zsh fragment looks up Debian/Ubuntu fzf key-bindings path"

summary
