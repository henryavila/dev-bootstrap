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
# shellcheck disable=SC1091
source "$HERE/../../lib/launch-wrapper.sh"

: "${BREW_BIN:?BREW_BIN not set — run through bootstrap.sh}"
: "${BREW_PREFIX:?BREW_PREFIX not set — run through bootstrap.sh}"

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

# Decide which launch path to use:
#   • canonical brew prefix (/opt/homebrew or /usr/local): use `brew services
#     start syncthing`. brew's auto-generated plist works because TCC is happy
#     with rootfs paths.
#   • custom prefix (/Volumes/External/homebrew, /opt/custom, ...):
#     `brew services start` produces a plist with ProgramArguments pointing
#     into the noowners volume → TCC sandbox blocks user-scope launchd → exit
#     78. Workaround: lib/launch-wrapper.sh generates a rootfs wrapper that
#     execs the external binary, inheriting TCC entitlement granted at
#     spawn. Empirical validation in dotfiles/.ai/memory/
#     feedback_tcc_entitlement_spawn_only.md.
#
# Bonus: Syncthing v2 needs the `serve` subcommand; brew's plist still uses
# v1 args. The wrapper path lets us pass v2 args correctly regardless of
# what brew ships in the formula.
case "$BREW_PREFIX" in
    /opt/homebrew|/usr/local) syncthing_use_wrapper=0 ;;
    *)                        syncthing_use_wrapper=1 ;;
esac

# Detection ladder for "already running" (any hit = "don't touch"):
#   1. UI listening on :8384 (definitive — covers all launch paths)
#   2. A syncthing process is running under this user
#   3. brew services reports started (canonical path)
#   4. wrapper-managed launchd reports running (custom path)
syncthing_running=0
if curl -sf -o /dev/null --max-time 2 http://127.0.0.1:8384 2>/dev/null; then
    syncthing_running=1
elif pgrep -u "$USER" -f 'syncthing' >/dev/null 2>&1; then
    syncthing_running=1
elif [[ "$syncthing_use_wrapper" == "0" ]] && \
     "$BREW_BIN" services list 2>/dev/null | awk '$1=="syncthing"{print $2}' | grep -qx 'started'; then
    syncthing_running=1
elif [[ "$syncthing_use_wrapper" == "1" ]] && \
     launchctl print "gui/$(id -u)/com.${USER}.syncthing" 2>/dev/null | grep -qE 'state[[:space:]]*=[[:space:]]*running'; then
    syncthing_running=1
fi

if [[ "$syncthing_running" == "1" ]]; then
    ok "syncthing already running (UI on :8384, or active LaunchAgent)"
elif [[ "$syncthing_use_wrapper" == "1" ]]; then
    info "BREW_PREFIX is custom ($BREW_PREFIX) — using launch-wrapper for syncthing"
    info "  (TCC sandbox blocks brew's user-scope plist when bin lives in a noowners volume;"
    info "   wrapper in rootfs passes spawn-time check and execs the brew binary)"
    syncthing_bin="$BREW_PREFIX/bin/syncthing"
    if [[ ! -x "$syncthing_bin" ]]; then
        fail "syncthing binary not executable at $syncthing_bin — brew install may have failed"
        exit 1
    fi
    launch_wrapper_install_extbrew \
        --svc syncthing \
        --label "com.${USER}.syncthing" \
        --brew-bin "$syncthing_bin" \
        -- serve --no-browser --no-restart
    # Wait briefly for syncthing to start listening on :8384
    info "waiting for syncthing UI to come up on :8384 (up to 20s)…"
    syncthing_up=0
    for _ in $(seq 1 20); do
        if curl -sf -o /dev/null --max-time 1 http://127.0.0.1:8384 2>/dev/null; then
            syncthing_up=1
            break
        fi
        sleep 1
    done
    if [[ "$syncthing_up" == "1" ]]; then
        ok "syncthing running via wrapper (com.${USER}.syncthing → $syncthing_bin serve …)"
    else
        fail "syncthing wrapper bootstrapped but UI not listening on :8384 after 20s"
        fail "  inspect: launchctl print gui/\$(id -u)/com.${USER}.syncthing"
        fail "  logs:    ~/.local/share/launch-wrapper/syncthing.{log,err}"
        exit 1
    fi
else
    info "brew services start syncthing"
    if ! "$BREW_BIN" services start syncthing; then
        fail "brew services start syncthing failed under canonical BREW_PREFIX ($BREW_PREFIX)"
        fail "  this is unexpected — investigate launchctl logs and brew formula"
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
