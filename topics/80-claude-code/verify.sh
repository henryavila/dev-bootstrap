#!/usr/bin/env bash
set -euo pipefail
# Ensure ~/.local/bin and ~/.bun/bin on PATH for CI where a new shell hasn't loaded ~/.bashrc
[[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
[[ -d "$HOME/.bun/bin"   ]] && export PATH="$HOME/.bun/bin:$PATH"

all_ok=1

# Bun runtime (required by claude-mem plugin worker)
if command -v bun >/dev/null 2>&1; then
    echo "  ✓ bun ($(bun --version))"
else
    echo "  ✗ bun MISSING (claude-mem worker will not start)"
    all_ok=0
fi

# Claude Code CLI
if command -v claude >/dev/null 2>&1; then
    echo "  ✓ claude"
else
    echo "  ✗ claude MISSING"
    all_ok=0
fi

# Syncthing binary
if command -v syncthing >/dev/null 2>&1; then
    echo "  ✓ syncthing installed"
    # Is the daemon running? (Linux: systemctl user; both: pgrep fallback)
    if systemctl --user is-active syncthing.service >/dev/null 2>&1; then
        echo "  ✓ syncthing service active (systemd --user)"
    elif command -v brew >/dev/null 2>&1 && brew services list 2>/dev/null | awk '$1=="syncthing"{print $2}' | grep -qx 'started'; then
        echo "  ✓ syncthing service active (brew services)"
    elif pgrep -f 'syncthing serve' >/dev/null 2>&1; then
        echo "  ✓ syncthing running (process)"
    else
        echo "  ! syncthing installed but daemon not running — start manually or re-run install"
    fi
else
    echo "  ✗ syncthing MISSING"
    all_ok=0
fi

[[ "$all_ok" == 1 ]] || exit 1
