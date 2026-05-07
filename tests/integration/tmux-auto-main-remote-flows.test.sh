#!/usr/bin/env bash
# tests/integration/tmux-auto-main-remote-flows.test.sh — dormant auto-main remote-flow regressions.
#
# These tests pin the user-visible failures:
#   - Moshi command already starts tmux; shell startup must not start another one.
#   - zsh + Powerlevel10k instant prompt redirects fd 0/1 during .zshrc; the
#     dormant auto-main experiment used to defer attachment until the prompt.
#   - Opted-in auto-main in an SSH login must leave a shell underneath so tmux detach
#     returns to that SSH shell instead of closing the SSH connection.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

BASH_FRAGMENT="$ROOT/topics/40-tmux/templates/bashrc.d-40-tmux.sh"
ZSH_FRAGMENT="$ROOT/topics/40-tmux/templates/zshrc.d-40-tmux.sh"
TESTROOT="$(mktemp -d /tmp/tmux-auto-main-remote-flows-test.XXXXXX)"
trap 'rm -rf "$TESTROOT"' EXIT INT TERM

STUBBIN="$TESTROOT/bin"
LOG="$TESTROOT/tmux.log"
TYPESCRIPT="$TESTROOT/script.out"
mkdir -p "$STUBBIN"

cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMUX_STUB_LOG:?}"

case "$1" in
    attach-session|attach)
        if [[ -n "${TMUX:-}" ]]; then
            printf 'sessions should be nested with care, unset $TMUX to force\n' >&2
            exit 1
        fi
        ;;
    detach)
        exit 0
        ;;
esac

exit 0
EOF
chmod +x "$STUBBIN/tmux"

quote_cmd() {
    local out="" q arg
    for arg in "$@"; do
        printf -v q '%q' "$arg"
        out="${out}${out:+ }$q"
    done
    printf '%s' "$out"
}

run_pty() {
    if script -q "$TYPESCRIPT" "$@" >/dev/null 2>&1; then
        return 0
    fi

    script -q -c "$(quote_cmd "$@")" "$TYPESCRIPT" >/dev/null 2>&1
}

run_bash_interactive() {
    local command="$1"
    shift || true
    : > "$LOG"
    run_pty env \
        PATH="$STUBBIN:/usr/bin:/bin" \
        TMUX_STUB_LOG="$LOG" \
    "$@" \
    /bin/bash --noprofile --norc -ic "$command" >/dev/null 2>&1
}

make_bash_home() {
    local home="$1"
    mkdir -p "$home/.bashrc.d"
    cp "$BASH_FRAGMENT" "$home/.bashrc.d/40-tmux.sh"

    cat > "$home/.bash_profile" <<'EOF'
[ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"
EOF
    cat > "$home/.bashrc" <<'EOF'
PATH="${TEST_TMUX_STUBBIN:-}:$PATH"
if [ -d "$HOME/.bashrc.d" ]; then
    for f in "$HOME"/.bashrc.d/*.sh; do
        [ -r "$f" ] && . "$f"
    done
fi
EOF
}

run_bash_login_command() {
    local home="$1"
    local command="$2"
    shift 2 || true
    : > "$LOG"
    run_pty env -i \
        HOME="$home" \
        PATH="$STUBBIN:/usr/bin:/bin" \
        TEST_TMUX_STUBBIN="$STUBBIN" \
        TMUX_STUB_LOG="$LOG" \
        "$@" \
        /bin/bash --login -ic "$command" >/dev/null 2>&1
}

run_zsh_p10k_like_startup() {
    local home="$1"
    shift || true
    : > "$LOG"
    mkdir -p "$home/.zshrc.d"
    cp "$ZSH_FRAGMENT" "$home/.zshrc.d/40-tmux.sh"
    cat > "$home/.zshrc" <<'EOF'
PATH="${TEST_TMUX_STUBBIN:-}:$PATH"
exec {__p9k_fd_0}<&0 {__p9k_fd_1}>&1 {__p9k_fd_2}>&2
exec 0</dev/null 1>"$HOME/p10k-output" 2>&1
__p10k_cleanup() {
    exec 0<&$__p9k_fd_0 1>&$__p9k_fd_1 2>&$__p9k_fd_2 {__p9k_fd_0}>&- {__p9k_fd_1}>&- {__p9k_fd_2}>&-
    unset __p9k_fd_0 __p9k_fd_1 __p9k_fd_2
}
__p10k_precmd_first() {
    zmodload zsh/sched
    sched +0 __p10k_cleanup
    precmd_functions=(${precmd_functions:#__p10k_precmd_first})
}
precmd_functions=(__p10k_precmd_first $precmd_functions)
if [ -d "$HOME/.zshrc.d" ]; then
    for f in "$HOME"/.zshrc.d/*.sh; do
        [ -r "$f" ] && source "$f"
    done
fi
EOF

    printf 'exit\n' | run_pty env -i \
        HOME="$home" \
        ZDOTDIR="$home" \
        PATH="$STUBBIN:/usr/bin:/bin" \
        TEST_TMUX_STUBBIN="$STUBBIN" \
        TMUX_STUB_LOG="$LOG" \
        "$@" \
        zsh -i >/dev/null 2>&1
}

tmux_calls() {
    grep -vE '^set-option ' "$LOG" 2>/dev/null || true
}

run_bash_interactive ". '$BASH_FRAGMENT'; eval 'ta main'" \
    TMUX=/tmp/tmux-stub,123,0
assert_eq "$(tmux_calls)" "switch-client -t main" \
    "mosh pre-attached tmux: ta helper switches clients instead of nesting"

home_p10k="$TESTROOT/home-p10k"
run_zsh_p10k_like_startup "$home_p10k"
assert_eq "$(tmux_calls)" "" \
    "zsh login with p10k-style redirected fds does not auto-attach main by default"

home_p10k_optin="$TESTROOT/home-p10k-optin"
run_zsh_p10k_like_startup "$home_p10k_optin" DEV_BOOTSTRAP_TMUX_AUTO_MAIN=1
assert_eq "$(tmux_calls)" "new-session -A -s main" \
    "DEV_BOOTSTRAP_TMUX_AUTO_MAIN=1 preserves p10k-style deferred auto-main experiment"

home_bash="$TESTROOT/home-bash"
make_bash_home "$home_bash"
run_bash_login_command "$home_bash" "td"
assert_eq "$(tmux_calls)" "detach" \
    "ssh login does not auto-main before td by default"

home_bash_optin="$TESTROOT/home-bash-optin"
make_bash_home "$home_bash_optin"
run_bash_login_command "$home_bash_optin" "td" DEV_BOOTSTRAP_TMUX_AUTO_MAIN=1
assert_eq "$(tmux_calls)" $'new-session -A -s main\ndetach' \
    "DEV_BOOTSTRAP_TMUX_AUTO_MAIN=1 still leaves the shell alive after tmux detach"

summary
