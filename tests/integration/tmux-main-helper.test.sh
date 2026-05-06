#!/usr/bin/env bash
# tests/integration/tmux-main-helper.test.sh — pin universal `tm` behavior.
#
# `tm` is the canonical "take me to tmux" helper. It must not create nested
# tmux clients when invoked from inside an existing tmux pane.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

BASH_FRAGMENT="$REPO_ROOT/topics/40-tmux/templates/bashrc.d-40-tmux.sh"
ZSH_FRAGMENT="$REPO_ROOT/topics/40-tmux/templates/zshrc.d-40-tmux.sh"
TESTROOT="$(mktemp -d /tmp/tmux-main-helper-test.XXXXXX)"
trap 'rm -rf "$TESTROOT"' EXIT INT TERM

STUBBIN="$TESTROOT/bin"
LOG="$TESTROOT/tmux.log"
mkdir -p "$STUBBIN"

cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMUX_STUB_LOG:?}"

case "$1" in
    has-session)
        if [[ "${TMUX_STUB_HAS_MAIN:-0}" == "1" ]]; then
            exit 0
        fi
        exit 1
        ;;
esac

exit 0
EOF
chmod +x "$STUBBIN/tmux"

run_tm() {
    local fragment="$1"
    local has_main="$2"
    local in_tmux="$3"
    : > "$LOG"

    local tmux_env=""
    if [[ "$in_tmux" == "1" ]]; then
        tmux_env="/tmp/tmux-stub,123,0"
    fi

    PATH="$STUBBIN:$PATH" \
    TMUX_STUB_LOG="$LOG" \
    TMUX_STUB_HAS_MAIN="$has_main" \
    TMUX="$tmux_env" \
    bash -lc "source '$fragment'; tm" >/dev/null 2>&1
}

assert_tm_log() {
    local fragment="$1"
    local fragment_name="$2"
    local has_main="$3"
    local in_tmux="$4"
    local expected="$5"
    local message="$6"

    run_tm "$fragment" "$has_main" "$in_tmux"
    assert_eq "$(cat "$LOG")" "$expected" "$fragment_name: $message"
}

for fragment in "$BASH_FRAGMENT" "$ZSH_FRAGMENT"; do
    name="$(basename "$fragment")"
    assert_file_contains "$fragment" "tm()" "$name defines tm as a function"
    assert_file_contains "$fragment" "tmux switch-client -t main" "$name switches instead of nesting inside tmux"

    assert_tm_log "$fragment" "$name" 0 0 \
        "new-session -A -s main" \
        "outside tmux attaches-or-creates main"

    assert_tm_log "$fragment" "$name" 1 1 \
        $'has-session -t main\nswitch-client -t main' \
        "inside tmux switches to existing main"

    assert_tm_log "$fragment" "$name" 0 1 \
        $'has-session -t main\nnew-session -d -s main\nswitch-client -t main' \
        "inside tmux creates detached main then switches"
done

summary
