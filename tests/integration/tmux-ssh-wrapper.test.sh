#!/usr/bin/env bash
# tests/integration/tmux-ssh-wrapper.test.sh
#
# Pin the intended tmux SSH indicator semantics:
#   - #H remains the host running the tmux server.
#   - the SSH card shows the outbound SSH destination of the focused pane.
#
# The shell fragment must therefore wrap local `ssh` invocations inside tmux,
# set a pane-local option before the connection starts, and clear it when the
# ssh command exits.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

BASH_FRAGMENT="$REPO_ROOT/topics/40-tmux/templates/bashrc.d-40-tmux.sh"
ZSH_FRAGMENT="$REPO_ROOT/topics/40-tmux/templates/zshrc.d-40-tmux.sh"
TESTROOT="$(mktemp -d /tmp/tmux-ssh-wrapper-test.XXXXXX)"
cleanup() { rm -rf "$TESTROOT"; }
trap cleanup EXIT INT TERM

STUBBIN="$TESTROOT/bin"
TMUX_LOG="$TESTROOT/tmux.log"
SSH_LOG="$TESTROOT/ssh.log"
mkdir -p "$STUBBIN"

cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMUX_STUB_LOG:?}"
exit 0
EOF
chmod +x "$STUBBIN/tmux"

cat > "$STUBBIN/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${SSH_STUB_LOG:?}"
exit "${SSH_STUB_RC:-0}"
EOF
chmod +x "$STUBBIN/ssh"

run_wrapped_ssh() {
    local fragment="$1"
    local in_tmux="$2"
    local ssh_rc="$3"
    shift 3

    : > "$TMUX_LOG"
    : > "$SSH_LOG"

    local tmux_env=""
    if [[ "$in_tmux" == "1" ]]; then
        tmux_env="/tmp/tmux-stub,123,0"
    fi

    PATH="$STUBBIN:$PATH" \
    TMUX_STUB_LOG="$TMUX_LOG" \
    SSH_STUB_LOG="$SSH_LOG" \
    SSH_STUB_RC="$ssh_rc" \
    TMUX="$tmux_env" \
    USER="localuser" \
    bash -c '
        fragment="$1"
        shift
        source "$fragment"
        : > "$TMUX_STUB_LOG"
        ssh "$@"
    ' _ "$fragment" "$@" >/dev/null 2>&1
}

assert_wrapped_context() {
    local fragment="$1"
    local fragment_name="$2"
    local expected_context="$3"
    local expected_ssh="$4"
    shift 4

    run_wrapped_ssh "$fragment" 1 0 "$@"
    assert_eq "$(cat "$SSH_LOG")" "$expected_ssh" \
        "$fragment_name: calls real ssh with original argv"
    assert_eq "$(cat "$TMUX_LOG")" \
        "set-option -p -q @dev_bootstrap_outbound_ssh_context $expected_context"$'\n'"set-option -p -q -u @dev_bootstrap_outbound_ssh_context" \
        "$fragment_name: sets and clears outbound SSH pane context"
}

for fragment in "$BASH_FRAGMENT" "$ZSH_FRAGMENT"; do
    name="$(basename "$fragment")"

    assert_file_contains "$fragment" "ssh()" "$name defines ssh as a wrapper"
    assert_file_contains "$fragment" "@dev_bootstrap_outbound_ssh_context" \
        "$name writes outbound SSH tmux context"

    assert_wrapped_context "$fragment" "$name" "localuser@mac" "mac" mac
    assert_wrapped_context "$fragment" "$name" "deploy@mac" "deploy@mac" deploy@mac
    assert_wrapped_context "$fragment" "$name" "root@mac" \
        $'-p\n2222\n-l\nroot\nmac\nuptime' \
        -p 2222 -l root mac uptime

    run_wrapped_ssh "$fragment" 0 0 mac
    assert_eq "$(cat "$TMUX_LOG")" "" \
        "$name: outside tmux does not write tmux SSH context"
    assert_eq "$(cat "$SSH_LOG")" "mac" \
        "$name: outside tmux still calls real ssh"

    run_wrapped_ssh "$fragment" 1 23 mac
    rc=$?
    assert_eq "$rc" "23" "$name: preserves ssh exit code"
    assert_eq "$(tail -1 "$TMUX_LOG")" \
        "set-option -p -q -u @dev_bootstrap_outbound_ssh_context" \
        "$name: clears tmux SSH context even when ssh fails"
done

summary
