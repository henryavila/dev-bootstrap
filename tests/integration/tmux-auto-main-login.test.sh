#!/usr/bin/env bash
# tests/integration/tmux-auto-main-login.test.sh — auto-attach login shells.
#
# 40-tmux is public baseline behavior: after bootstrap, a fresh interactive
# login shell should enter the canonical tmux "main" session unless it is
# already inside tmux. This test exercises the deployed fragment through
# bash/zsh login loaders in a pseudo-TTY, not by calling the helper directly.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

BASH_FRAGMENT="$ROOT/topics/40-tmux/templates/bashrc.d-40-tmux.sh"
ZSH_FRAGMENT="$ROOT/topics/40-tmux/templates/zshrc.d-40-tmux.sh"
TESTROOT="$(mktemp -d /tmp/tmux-auto-main-login-test.XXXXXX)"
trap 'rm -rf "$TESTROOT"' EXIT INT TERM

STUBBIN="$TESTROOT/bin"
LOG="$TESTROOT/tmux.log"
TYPESCRIPT="$TESTROOT/script.out"
mkdir -p "$STUBBIN"

cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMUX_STUB_LOG:?}"
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

make_home() {
    local home="$1"
    mkdir -p "$home/.bashrc.d" "$home/.zshrc.d"
    cp "$BASH_FRAGMENT" "$home/.bashrc.d/40-tmux.sh"
    cp "$ZSH_FRAGMENT" "$home/.zshrc.d/40-tmux.sh"

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
    cat > "$home/.zshrc" <<'EOF'
PATH="${TEST_TMUX_STUBBIN:-}:$PATH"
if [ -d "$HOME/.zshrc.d" ]; then
    for f in "$HOME"/.zshrc.d/*.sh; do
        [ -r "$f" ] && source "$f"
    done
fi
EOF
}

assert_log() {
    local expected="$1"
    local message="$2"
    local actual

    actual="$(grep -vE '^set-option ' "$LOG" 2>/dev/null || true)"
    assert_eq "$actual" "$expected" "$message"
}

run_bash_login() {
    local home="$1"
    shift
    : > "$LOG"
    run_pty env -i \
        HOME="$home" \
        PATH="$STUBBIN:/usr/bin:/bin" \
        TEST_TMUX_STUBBIN="$STUBBIN" \
        TMUX_STUB_LOG="$LOG" \
        "$@" \
        /bin/bash --login -ic 'exit'
}

run_zsh_login() {
    local home="$1"
    shift
    : > "$LOG"
    run_pty env -i \
        HOME="$home" \
        ZDOTDIR="$home" \
        PATH="$STUBBIN:/usr/bin:/bin" \
        TEST_TMUX_STUBBIN="$STUBBIN" \
        TMUX_STUB_LOG="$LOG" \
        "$@" \
        zsh -lic 'exit'
}

run_noninteractive_source() {
    local fragment="$1"
    : > "$LOG"
    env -i \
        HOME="$TESTROOT/noninteractive-home" \
        PATH="$STUBBIN:/usr/bin:/bin" \
        TMUX_STUB_LOG="$LOG" \
        /bin/bash -c ". '$fragment'" >/dev/null 2>&1
}

home_bash="$TESTROOT/home-bash"
make_home "$home_bash"
run_bash_login "$home_bash"
assert_log "new-session -A -s main" "bash login outside tmux auto-attaches main"

home_zsh="$TESTROOT/home-zsh"
make_home "$home_zsh"
run_zsh_login "$home_zsh"
assert_log "new-session -A -s main" "zsh login outside tmux auto-attaches main"

home_inside="$TESTROOT/home-inside"
make_home "$home_inside"
run_zsh_login "$home_inside" TMUX=/tmp/tmux-stub,123,0
assert_log "" "inside tmux does not auto-start nested client"

home_optout="$TESTROOT/home-optout"
make_home "$home_optout"
run_zsh_login "$home_optout" DEV_BOOTSTRAP_TMUX_AUTO_MAIN=0
assert_log "" "DEV_BOOTSTRAP_TMUX_AUTO_MAIN=0 disables auto-attach"

run_noninteractive_source "$BASH_FRAGMENT"
assert_log "" "non-interactive source does not auto-attach"

summary
