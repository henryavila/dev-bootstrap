#!/usr/bin/env bash
# tests/integration/tmux-mac-standalone-brew.test.sh
#
# Regression guard for incremental updates: scripts/runners/auto-update.sh
# runs changed topic installers directly, outside setup.sh. Mac topic
# installers that need Homebrew must therefore recover BREW_BIN themselves
# instead of assuming setup.sh exported it.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

TESTROOT="$(mktemp -d /tmp/tmux-mac-standalone-brew.XXXXXX)"
cleanup() { rm -rf "$TESTROOT"; }
trap cleanup EXIT INT TERM

STUBBIN="$TESTROOT/bin"
HOME_DIR="$TESTROOT/home"
FAKE_PREFIX="$TESTROOT/homebrew"
LOG="$TESTROOT/run.log"
mkdir -p "$STUBBIN" "$HOME_DIR/.tmux/plugins/tpm/.git" \
    "$HOME_DIR/.tmux/plugins/tmux/.git" "$FAKE_PREFIX"

cat > "$STUBBIN/brew" <<'FAKEBREW'
#!/usr/bin/env bash
case "${1:-}" in
    --prefix)
        printf '%s\n' "$FAKE_BREW_PREFIX"
        ;;
    list)
        exit 0
        ;;
    install)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
FAKEBREW
chmod +x "$STUBBIN/brew"

if PATH="$STUBBIN:$PATH" \
   HOME="$HOME_DIR" \
   FAKE_BREW_PREFIX="$FAKE_PREFIX" \
   BREW_BIN='' \
   BREW_PREFIX='' \
   bash "$ROOT/topics/40-tmux/install.mac.sh" >"$LOG" 2>&1; then
    pass "40-tmux/install.mac.sh runs standalone with BREW_BIN unset"
else
    rc=$?
    fail "40-tmux/install.mac.sh exited $rc with BREW_BIN unset"
    sed 's/^/      /' "$LOG" >&2
fi

if grep -q 'BREW_BIN not set' "$LOG" 2>/dev/null; then
    fail "standalone topic install still aborts with BREW_BIN not set"
    grep -n 'BREW_BIN not set' "$LOG" | sed 's/^/      /' >&2
else
    pass "standalone topic install does not emit BREW_BIN not set"
fi

assert_file_contains "$LOG" "tmux already installed" \
    "40-tmux/install.mac.sh used detected fake brew"

summary
