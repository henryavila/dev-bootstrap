#!/usr/bin/env bash
# zsh-default-shell must not chsh until mesh ~/.zshrc is in place. Otherwise
# Windows Terminal starts zsh with Ubuntu's empty/default zshrc — fzf only
# works in bash (package bash-completion) and the session looks "half set up".
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

SCRIPT="$WS/topics/shell-terminal/zsh-default-shell.sh"
assert_file_exists "$SCRIPT" "zsh-default-shell.sh exists"
assert_file_contains "$SCRIPT" 'zshrc.d' \
    "zsh-default-shell.sh refuses chsh until ~/.zshrc loads zshrc.d"

TMP="$(mktemp -d /tmp/zsh-chsh-guard.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fake="$TMP/bin"
mkdir -p "$fake"
SUDO_LOG="$TMP/sudo.log"
: > "$SUDO_LOG"

cat > "$fake/zsh" <<'EOF'
#!/bin/sh
echo /tmp/fake/zsh
EOF
chmod +x "$fake/zsh"

cat > "$fake/sudo" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$SUDO_LOG"
exit 0
EOF
chmod +x "$fake/sudo"

# Case 1: no ~/.zshrc → must not invoke sudo/chsh.
home1="$TMP/home-empty"
mkdir -p "$home1"
(
    export HOME="$home1"
    export PATH="$fake:/usr/bin:/bin"
    export CHSH_AUTO=1
    export USER=tester
    # shellcheck source=/dev/null
    . "$SCRIPT"
    install
) >"$TMP/out-empty.txt" 2>&1 || true

if [[ -s "$SUDO_LOG" ]]; then
    fail "chsh/sudo must not run when ~/.zshrc is missing"
    printf '      sudo log: %s\n' "$(cat "$SUDO_LOG")" >&2
else
    pass "no chsh when ~/.zshrc is missing"
fi

# Case 2: unmarked / stock zshrc that does not load zshrc.d → still no chsh.
: > "$SUDO_LOG"
home2="$TMP/home-stock"
mkdir -p "$home2"
printf '%s\n' '# stock zshrc' > "$home2/.zshrc"
(
    export HOME="$home2"
    export PATH="$fake:/usr/bin:/bin"
    export CHSH_AUTO=1
    export USER=tester
    # shellcheck source=/dev/null
    . "$SCRIPT"
    install
) >"$TMP/out-stock.txt" 2>&1 || true

if [[ -s "$SUDO_LOG" ]]; then
    fail "chsh/sudo must not run when ~/.zshrc does not load zshrc.d"
else
    pass "no chsh when ~/.zshrc does not load zshrc.d"
fi

# Case 3: mesh-managed zshrc that sources zshrc.d → sudo/chsh is attempted.
: > "$SUDO_LOG"
home3="$TMP/home-mesh"
mkdir -p "$home3/.zshrc.d"
cat > "$home3/.zshrc" <<'EOF'
# managed by mesh-workstation
if [ -d "$HOME/.zshrc.d" ]; then
    for f in "$HOME"/.zshrc.d/*.sh; do
        [ -r "$f" ] && source "$f"
    done
fi
EOF
(
    export HOME="$home3"
    export PATH="$fake:/usr/bin:/bin"
    export CHSH_AUTO=1
    export USER=tester
    export NON_INTERACTIVE=1
    # shellcheck source=/dev/null
    . "$SCRIPT"
    install
) >"$TMP/out-mesh.txt" 2>&1 || true

if grep -q 'chsh' "$SUDO_LOG"; then
    pass "chsh is attempted once mesh ~/.zshrc sources zshrc.d"
else
    fail "chsh should run when mesh ~/.zshrc is in place"
    printf '      sudo log: [%s]\n      output: %s\n' "$(cat "$SUDO_LOG")" "$(cat "$TMP/out-mesh.txt")" >&2
fi

summary
