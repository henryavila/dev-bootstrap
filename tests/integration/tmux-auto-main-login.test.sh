#!/usr/bin/env bash
# tests/integration/tmux-auto-main-login.test.sh — dormant auto-main login flow.
#
# The auto-main implementation is intentionally preserved but inactive by
# default. This test exercises the deployed fragment through bash/zsh login
# loaders in a pseudo-TTY so accidental reactivation is caught.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

BASH_FRAGMENT="$ROOT/topics/40-tmux/templates/bashrc.d-40-tmux.sh"
ZSH_FRAGMENT="$ROOT/topics/40-tmux/templates/zshrc.d-40-tmux.sh"
BASH_ENV_FRAGMENT="$ROOT/topics/30-shell/templates/bashrc.d-00-dev-bootstrap-env.sh"
ZSH_ENV_FRAGMENT="$ROOT/topics/30-shell/templates/zshrc.d-00-dev-bootstrap-env.sh"
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

install_legacy_auto_main_fragment() {
    local path="$1"
    cat > "$path" <<'EOF'
command -v tmux >/dev/null 2>&1 || return 0
if [ "${DEV_BOOTSTRAP_TMUX_AUTO_MAIN:-1}" != "0" ]; then
    case "$-" in
        *i*) tmux new-session -A -s main ;;
    esac
fi
EOF
}

home_bash="$TESTROOT/home-bash"
make_home "$home_bash"
run_bash_login "$home_bash"
assert_log "" "bash login outside tmux does not auto-attach main by default"

home_zsh="$TESTROOT/home-zsh"
make_home "$home_zsh"
run_zsh_login "$home_zsh"
assert_log "" "zsh login outside tmux does not auto-attach main by default"

home_bash_optin="$TESTROOT/home-bash-optin"
make_home "$home_bash_optin"
run_bash_login "$home_bash_optin" DEV_BOOTSTRAP_TMUX_AUTO_MAIN=1
assert_log "new-session -A -s main" "DEV_BOOTSTRAP_TMUX_AUTO_MAIN=1 enables bash auto-main experiment"

home_zsh_optin="$TESTROOT/home-zsh-optin"
make_home "$home_zsh_optin"
run_zsh_login "$home_zsh_optin" DEV_BOOTSTRAP_TMUX_AUTO_MAIN=1
assert_log "new-session -A -s main" "DEV_BOOTSTRAP_TMUX_AUTO_MAIN=1 enables zsh auto-main experiment"

home_inside="$TESTROOT/home-inside"
make_home "$home_inside"
run_zsh_login "$home_inside" TMUX=/tmp/tmux-stub,123,0
assert_log "" "inside tmux does not auto-start nested client"

home_optout="$TESTROOT/home-optout"
make_home "$home_optout"
run_zsh_login "$home_optout" DEV_BOOTSTRAP_TMUX_AUTO_MAIN=0
assert_log "" "DEV_BOOTSTRAP_TMUX_AUTO_MAIN=0 keeps auto-attach disabled"

home_legacy_bash="$TESTROOT/home-legacy-bash"
make_home "$home_legacy_bash"
cp "$BASH_ENV_FRAGMENT" "$home_legacy_bash/.bashrc.d/00-dev-bootstrap-env.sh"
install_legacy_auto_main_fragment "$home_legacy_bash/.bashrc.d/40-tmux.sh"
run_bash_login "$home_legacy_bash"
assert_log "" "30-shell env fragment disables older bash auto-main fragment after update"

home_legacy_zsh="$TESTROOT/home-legacy-zsh"
make_home "$home_legacy_zsh"
cp "$ZSH_ENV_FRAGMENT" "$home_legacy_zsh/.zshrc.d/00-dev-bootstrap-env.sh"
install_legacy_auto_main_fragment "$home_legacy_zsh/.zshrc.d/40-tmux.sh"
run_zsh_login "$home_legacy_zsh"
assert_log "" "30-shell env fragment disables older zsh auto-main fragment after update"

run_noninteractive_source "$BASH_FRAGMENT"
assert_log "" "non-interactive source does not auto-attach"

summary
