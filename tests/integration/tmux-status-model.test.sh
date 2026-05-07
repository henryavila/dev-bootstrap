#!/usr/bin/env bash
# tests/integration/tmux-status-model.test.sh
#
# Pin the approved tmux status model:
#   - nested tmux bars are intentional for remote work;
#   - the status bar shows cwd + user@host for the tmux server;
#   - tmux does not try to infer or display SSH connection state.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

TMUX_CONF="$REPO_ROOT/topics/40-tmux/templates/tmux.conf"
BASH_FRAGMENT="$REPO_ROOT/topics/40-tmux/templates/bashrc.d-40-tmux.sh"
ZSH_FRAGMENT="$REPO_ROOT/topics/40-tmux/templates/zshrc.d-40-tmux.sh"

assert_file_exists "$TMUX_CONF" \
    "tmux.conf exists"
assert_file_exists "$BASH_FRAGMENT" \
    "bash tmux fragment exists"
assert_file_exists "$ZSH_FRAGMENT" \
    "zsh tmux fragment exists"

assert_pattern_present "$TMUX_CONF" '@dev_bootstrap_pane_cwd' \
    "tmux status keeps shell-reported cwd"
assert_pattern_present "$TMUX_CONF" 'status-right.*#\{\?#\{@dev_bootstrap_pane_cwd\},#\{b:@dev_bootstrap_pane_cwd\},#\{b:pane_current_path\}\}' \
    "tmux status falls back to pane_current_path"
assert_pattern_present "$TMUX_CONF" '#\{user\}@#h' \
    "tmux host card renders user@short-host"
assert_pattern_present "$TMUX_CONF" 'Nested tmux bars are intentional' \
    "tmux.conf documents nested bars as the SSH/remote-work model"

assert_pattern_absent "$TMUX_CONF" '@dev_bootstrap_outbound_ssh_context' \
    "tmux status does not track outbound SSH pane context"
assert_pattern_absent "$TMUX_CONF" 'SSH_CONNECTION' \
    "tmux status does not use inbound SSH_CONNECTION"
assert_pattern_absent "$TMUX_CONF" '󰣀' \
    "tmux status has no separate SSH icon/card"

for fragment in "$BASH_FRAGMENT" "$ZSH_FRAGMENT"; do
    base="$(basename "$fragment")"
    assert_pattern_present "$fragment" '@dev_bootstrap_pane_cwd' \
        "$base reports cwd into tmux"
    assert_pattern_absent "$fragment" '@dev_bootstrap_outbound_ssh_context' \
        "$base does not write SSH status context"
    assert_pattern_absent "$fragment" 'ssh\(\)' \
        "$base does not wrap ssh"
    assert_pattern_absent "$fragment" '__dev_bootstrap_tmux_ssh_context_from_args' \
        "$base has no SSH arg parser"
done

summary
