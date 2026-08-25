#!/usr/bin/env bash
# tests/integration/tmux-main-helper.test.sh — pin universal tmux helper behavior.
#
# `tm` is the canonical "take me to tmux" helper. `tmux_project` is the
# reusable "take me to this named project session rooted at this directory"
# helper for private project shortcuts. Neither may create nested tmux clients
# when invoked from inside an existing tmux pane.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

BASH_FRAGMENT="$REPO_ROOT/topics/shell-terminal/templates/tmux/bashrc.d-40-tmux.sh"
ZSH_FRAGMENT="$REPO_ROOT/topics/shell-terminal/templates/tmux/zshrc.d-40-tmux.sh"
TESTROOT="$(mktemp -d /tmp/tmux-main-helper-test.XXXXXX)"
trap 'rm -rf "$TESTROOT"' EXIT INT TERM

STUBBIN="$TESTROOT/bin"
LOG="$TESTROOT/tmux.log"
PROJECT_DIR="$TESTROOT/project"
mkdir -p "$STUBBIN" "$PROJECT_DIR"

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
    bash -c "source '$fragment'; tm" >/dev/null 2>&1
}

run_tmux_project() {
    local fragment="$1"
    local has_session="$2"
    local in_tmux="$3"
    local project_dir="$4"
    : > "$LOG"

    local tmux_env=""
    if [[ "$in_tmux" == "1" ]]; then
        tmux_env="/tmp/tmux-stub,123,0"
    fi

    PATH="$STUBBIN:$PATH" \
    TMUX_STUB_LOG="$LOG" \
    TMUX_STUB_HAS_MAIN="$has_session" \
    TMUX="$tmux_env" \
    bash -c "source '$fragment'; tmux_project work '$project_dir'" \
        >"$TESTROOT/stdout" 2>"$TESTROOT/stderr"
}

assert_tm_log() {
    local fragment="$1"
    local fragment_name="$2"
    local has_main="$3"
    local in_tmux="$4"
    local expected="$5"
    local message="$6"
    local actual

    run_tm "$fragment" "$has_main" "$in_tmux"
    actual="$(grep -vE '^set-option ' "$LOG" 2>/dev/null || true)"
    assert_eq "$actual" "$expected" "$fragment_name: $message"
}

assert_tmux_project_log() {
    local fragment="$1"
    local fragment_name="$2"
    local has_session="$3"
    local in_tmux="$4"
    local expected="$5"
    local message="$6"
    local actual

    run_tmux_project "$fragment" "$has_session" "$in_tmux" "$PROJECT_DIR"
    actual="$(grep -vE '^set-option ' "$LOG" 2>/dev/null || true)"
    assert_eq "$actual" "$expected" "$fragment_name: $message"
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

    assert_file_contains "$fragment" "tmux_project()" "$name defines tmux_project as a function"

    assert_tmux_project_log "$fragment" "$name" 0 0 \
        "new-session -A -s work -c $PROJECT_DIR" \
        "tmux_project outside tmux attaches-or-creates with cwd"

    assert_tmux_project_log "$fragment" "$name" 1 1 \
        $'has-session -t work\nswitch-client -t work' \
        "tmux_project inside tmux switches to existing session"

    assert_tmux_project_log "$fragment" "$name" 0 1 \
        $'has-session -t work\nnew-session -d -s work -c '"$PROJECT_DIR"$'\nswitch-client -t work' \
        "tmux_project inside tmux creates detached session with cwd then switches"

    missing_dir="$TESTROOT/missing"
    if run_tmux_project "$fragment" 0 0 "$missing_dir"; then
        fail "$name: tmux_project rejects missing directories"
    else
        assert_file_contains "$TESTROOT/stderr" "tmux_project: directory not found: $missing_dir" \
            "$name: tmux_project reports missing directory"
        actual="$(grep -vE '^set-option ' "$LOG" 2>/dev/null || true)"
        assert_eq "$actual" "" "$name: tmux_project does not invoke tmux for missing directory"
    fi
done

summary
