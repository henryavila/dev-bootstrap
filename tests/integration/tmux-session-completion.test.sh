#!/usr/bin/env bash
# tests/integration/tmux-session-completion.test.sh — pin Tab-completion of
# active tmux session names for the `ta` helper.
#
# `ta <session>` attaches/switches to a session by name. Because `ta` is a
# shell function (not an alias to `tmux attach`), neither shell completes
# session names for it out of the box. Both fragments must register a
# completion that lists live sessions via `tmux list-sessions`.
#
# Completion of `tn`/`tmux_project` is intentionally NOT provided: those take
# a *new* session name. `td`/`tm` take no argument. Only `ta` benefits.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

BASH_FRAGMENT="$REPO_ROOT/topics/shell-terminal/templates/tmux/bashrc.d-40-tmux.sh"
ZSH_FRAGMENT="$REPO_ROOT/topics/shell-terminal/templates/tmux/zshrc.d-40-tmux.sh"

assert_file_exists "$BASH_FRAGMENT" "tmux completion — bashrc fragment exists"
assert_file_exists "$ZSH_FRAGMENT" "tmux completion — zshrc fragment exists"

# ── Static contract ─────────────────────────────────────────────────────────
# Both fragments source live sessions the same way and register on `ta`.
for f in "$BASH_FRAGMENT" "$ZSH_FRAGMENT"; do
    base="$(basename "$f")"
    assert_pattern_present "$f" '_mesh_tmux_sessions' \
        "$base — defines the _mesh_tmux_sessions completion helper"
    assert_pattern_present "$f" "tmux list-sessions -F '#{session_name}'" \
        "$base — enumerates live sessions by name"
done

assert_pattern_present "$BASH_FRAGMENT" 'complete -F _mesh_tmux_sessions ta' \
    "bashrc — registers session completion on 'ta'"
assert_pattern_present "$ZSH_FRAGMENT" 'compdef _mesh_tmux_sessions ta' \
    "zshrc — registers session completion on 'ta'"
# zsh: only register when the completion system is loaded (mirrors git topic).
assert_pattern_present "$ZSH_FRAGMENT" 'command -v compdef' \
    "zshrc — guards compdef on completion system being initialised"

# ── Syntax validity ─────────────────────────────────────────────────────────
if bash -n "$BASH_FRAGMENT" 2>/tmp/tmux-comp-bash-syntax.err; then
    pass "bashrc — fragment parses under 'bash -n'"
else
    fail "bashrc — fragment parses under 'bash -n' ($(cat /tmp/tmux-comp-bash-syntax.err))"
fi

if command -v zsh >/dev/null 2>&1; then
    if zsh -n "$ZSH_FRAGMENT" 2>/tmp/tmux-comp-zsh-syntax.err; then
        pass "zshrc — fragment parses under 'zsh -n'"
    else
        fail "zshrc — fragment parses under 'zsh -n' ($(cat /tmp/tmux-comp-zsh-syntax.err))"
    fi
else
    pass "zshrc — 'zsh -n' skipped (zsh not on PATH)"
fi

# ── Functional: bash completion returns live session names ──────────────────
# Stub `tmux` so list-sessions yields a known set, source the fragment, then
# drive the completion function the way bash's completion machinery does.
TESTROOT="$(mktemp -d /tmp/tmux-session-completion-test.XXXXXX)"
trap 'rm -rf "$TESTROOT"' EXIT INT TERM
STUBBIN="$TESTROOT/bin"
mkdir -p "$STUBBIN"

cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
# Minimal stub: only `list-sessions -F '#{session_name}'` is exercised here.
if [ "$1" = "list-sessions" ]; then
    printf '%s\n' main work scratch
    exit 0
fi
exit 0
EOF
chmod +x "$STUBBIN/tmux"

run_bash_completion() {
    # $1 = current word being completed. Echoes one candidate per line.
    local cur="$1"
    PATH="$STUBBIN:$PATH" bash --noprofile --norc -c '
        set -uo pipefail
        source "$1"
        COMP_WORDS=(ta "$2")
        COMP_CWORD=1
        _mesh_tmux_sessions
        printf "%s\n" "${COMPREPLY[@]}"
    ' _ "$BASH_FRAGMENT" "$cur"
}

all="$(run_bash_completion "" | sort | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "$all" "main scratch work" \
    "bashrc — empty prefix completes every live session"

filtered="$(run_bash_completion "w" | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "$filtered" "work" \
    "bashrc — prefix 'w' narrows to matching sessions only"

none="$(run_bash_completion "zzz" | sed '/^$/d')"
assert_eq "$none" "" \
    "bashrc — non-matching prefix yields no candidates"

summary
