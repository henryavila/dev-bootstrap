#!/usr/bin/env bash
# 80-claude-code (mac): install Claude Code CLI + Syncthing via brew.
#
# Syncthing is used to converge a curated subset of ~/.claude/ and ~/.claude-mem/
# between N personal machines — see the user's dotfiles (claude/ folder) for the
# .stignore files and pairing docs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

: "${BREW_BIN:?BREW_BIN not set — run through bootstrap.sh}"

# ---------- Bun runtime ----------
# Required by claude-mem plugin (worker service managed by Bun on port 37777).
# The plugin ships a smart-install.js that auto-installs Bun via hook when
# missing — but that only fires on first Claude session with the plugin active,
# which is a fragile chain. Installing explicitly here guarantees claude-mem
# works from the first use.
if command -v bun >/dev/null 2>&1; then
    ok "bun already installed ($(bun --version 2>&1))"
elif [[ -x "$HOME/.bun/bin/bun" ]]; then
    export PATH="$HOME/.bun/bin:$PATH"
    ok "bun installed at ~/.bun/bin/bun ($("$HOME/.bun/bin/bun" --version))"
else
    info "installing Bun via official installer (adds ~/.bun/bin to shell rc)"
    curl -fsSL https://bun.sh/install | bash
    if [[ -x "$HOME/.bun/bin/bun" ]]; then
        export PATH="$HOME/.bun/bin:$PATH"
        ok "bun installed ($("$HOME/.bun/bin/bun" --version))"
    else
        fail "bun install failed — check output above"
        exit 1
    fi
fi

# ---------- Claude Code CLI ----------
if command -v claude >/dev/null 2>&1; then
    ok "claude already installed ($(claude --version 2>&1 | head -1))"
else
    info "installing Claude Code via official installer"
    curl -fsSL https://claude.ai/install.sh | bash
    if command -v claude >/dev/null 2>&1; then
        ok "claude installed ($(claude --version 2>&1 | head -1))"
    elif [[ -x "$HOME/.local/bin/claude" ]]; then
        ok "claude installed at ~/.local/bin/claude (open new shell)"
    else
        fail "claude install failed — check output above"
        exit 1
    fi
fi

# ---------- Syncthing via brew ----------
if "$BREW_BIN" list --formula syncthing >/dev/null 2>&1; then
    ok "syncthing already installed (brew)"
else
    info "brew install syncthing"
    "$BREW_BIN" install syncthing
fi

# Start as a brew service (auto-restart on login), unless syncthing is
# already running via a different path.
#
# On some Mac setups (notably: brew on external volume /Volumes/External,
# or Syncthing v2 which needs the `serve` subcommand that brew's v1 plist
# doesn't use), `brew services start syncthing` fails with launchctl errors
# 78 (EX_CONFIG) or 5 (EIO). Workaround: run Syncthing via a custom
# LaunchAgent (e.g. com.<user>.syncthing.plist) — see the
# CONVERGENCE_PLAYBOOK "Known issues" section. If such a setup is already
# active we skip the brew `services start` to avoid a redundant failure.
#
# Detection ladder (any hit = "don't touch"):
#   1. UI listening on :8384 (definitive — covers all launch paths)
#   2. A syncthing process is running under this user
#   3. brew services reports started
syncthing_running=0
if curl -sf -o /dev/null --max-time 2 http://127.0.0.1:8384 2>/dev/null; then
    syncthing_running=1
elif pgrep -u "$USER" -f 'syncthing' >/dev/null 2>&1; then
    syncthing_running=1
elif "$BREW_BIN" services list 2>/dev/null | awk '$1=="syncthing"{print $2}' | grep -qx 'started'; then
    syncthing_running=1
fi

if [[ "$syncthing_running" == "1" ]]; then
    ok "syncthing already running (UI on :8384, or active LaunchAgent)"
else
    info "brew services start syncthing"
    if ! "$BREW_BIN" services start syncthing; then
        warn "brew services start syncthing failed"
        warn "common causes on this host:"
        warn "  • brew installed on external volume → TCC sandbox blocks launchctl"
        warn "  • Syncthing v2 needs 'serve' subcommand; brew's v1 plist doesn't"
        warn "workaround: create ~/Library/LaunchAgents/com.<user>.syncthing.plist"
        warn "            with '<string>syncthing</string><string>serve</string>' then"
        warn "            launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.<user>.syncthing.plist"
        warn "see dotfiles/claude/CONVERGENCE_PLAYBOOK.md 'Known issues' for full context"
        exit 1
    fi
fi

# Wait briefly for config init
if [[ ! -f "$HOME/Library/Application Support/Syncthing/config.xml" ]]; then
    info "waiting for syncthing to initialize config (up to 10s)…"
    for _ in $(seq 1 10); do
        sleep 1
        [[ -f "$HOME/Library/Application Support/Syncthing/config.xml" ]] && break
    done
fi

info "syncthing web UI: http://localhost:8384"
info "  1. First access: set an admin password in Settings → GUI"
info "  2. Get this device's ID: syncthing --device-id"
info "  3. Pair with other machines + accept shared folders (see dotfiles/claude/scripts/syncthing-setup.md)"

ok "80-claude-code done"
