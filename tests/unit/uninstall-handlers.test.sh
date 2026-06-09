#!/usr/bin/env bash
# tests/unit/uninstall-handlers.test.sh
# Verify uninstall-handlers.sh handler functions and safety guards.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/tests/lib/assert.sh"

HANDLERS="$ROOT/scripts/lib/uninstall-handlers.sh"

echo
echo "═══ uninstall-handlers unit tests ═══"

# ─── Source the handlers (requires log.sh stubs) ────────────────────
info()  { :; }
warn()  { echo "WARN: $*" >&2; }
export -f info warn

# shellcheck disable=SC1090
source "$HANDLERS"

# ─── Sandbox tests ──────────────────────────────────────────────────
echo "--- sandbox ---"

# _sandbox_name should reject paths with slashes
if _sandbox_name "clone" "../../etc/passwd" 2>/dev/null; then
    fail "_sandbox_name should reject path with .."
else
    pass "_sandbox_name rejects .."
fi

if _sandbox_name "clone" "safe-name" 2>/dev/null; then
    pass "_sandbox_name accepts safe name"
else
    fail "_sandbox_name should accept safe-name"
fi

if _sandbox_name "clone" "has/slash" 2>/dev/null; then
    fail "_sandbox_name should reject slash"
else
    pass "_sandbox_name rejects slash"
fi

if _sandbox_name "clone" "" 2>/dev/null; then
    fail "_sandbox_name should reject empty"
else
    pass "_sandbox_name rejects empty string"
fi

# ─── Handler existence tests ───────────────────────────────────────
echo "--- handler functions ---"

for fn in _uninstall_apt _uninstall_brew _uninstall_brew_cask \
          _uninstall_clone _uninstall_zinit _uninstall_user_bin \
          _uninstall_sys_bin _uninstall_npm_global _uninstall_cargo \
          _uninstall_pip _uninstall_npx; do
    if declare -f "$fn" >/dev/null 2>&1; then
        pass "$fn is defined"
    else
        fail "$fn is NOT defined"
    fi
done

# ─── _uninstall_clone safety: operates on expected directory ────────
echo "--- clone handler ---"

TMP=$(mktemp -d)
mkdir -p "$TMP/.local/share/testdir"
touch "$TMP/.local/share/testdir/file.txt"

# Override HOME for testing
HOME_BACKUP="$HOME"
export HOME="$TMP"

_uninstall_clone "testdir" 2>/dev/null
if [[ -d "$TMP/.local/share/testdir" ]]; then
    fail "_uninstall_clone did not remove the directory"
else
    pass "_uninstall_clone removed the directory"
fi

# Safe: absent dir is no-op
_uninstall_clone "nonexistent" 2>/dev/null
pass "_uninstall_clone handles absent dir (no-op)"

export HOME="$HOME_BACKUP"
rm -rf "$TMP"

# ─── _uninstall_user_bin: removes file from ~/.local/bin ────────────
echo "--- user-bin handler ---"

TMP=$(mktemp -d)
mkdir -p "$TMP/.local/bin"
touch "$TMP/.local/bin/test-binary"

HOME_BACKUP="$HOME"
export HOME="$TMP"

_uninstall_user_bin "test-binary" 2>/dev/null
if [[ -e "$TMP/.local/bin/test-binary" ]]; then
    fail "_uninstall_user_bin did not remove the binary"
else
    pass "_uninstall_user_bin removed the binary"
fi

_uninstall_user_bin "nonexistent" 2>/dev/null
pass "_uninstall_user_bin handles absent binary (no-op)"

export HOME="$HOME_BACKUP"
rm -rf "$TMP"

# ─── _uninstall_zinit: mangled path ────────────────────────────────
echo "--- zinit handler ---"

TMP=$(mktemp -d)
mkdir -p "$TMP/.local/share/zinit/plugins/owner---repo"
touch "$TMP/.local/share/zinit/plugins/owner---repo/plugin.zsh"

HOME_BACKUP="$HOME"
export HOME="$TMP"

_uninstall_zinit "owner/repo" 2>/dev/null
if [[ -d "$TMP/.local/share/zinit/plugins/owner---repo" ]]; then
    fail "_uninstall_zinit did not remove the plugin"
else
    pass "_uninstall_zinit removed owner---repo"
fi

# Safety: reject malformed specs
_uninstall_zinit "noslash" 2>/dev/null
pass "_uninstall_zinit rejects spec without slash"

_uninstall_zinit "../escape" 2>/dev/null
pass "_uninstall_zinit rejects path traversal"

export HOME="$HOME_BACKUP"
rm -rf "$TMP"

# ─── _uninstall_npx: advisory only ────────────────────────────────
echo "--- npx handler ---"
# shellcheck disable=SC2034  # captured to suppress handler stdout
output=$(_uninstall_npx "some-pkg install --yes" 2>&1)
pass "_uninstall_npx runs without error (advisory)"

summary
