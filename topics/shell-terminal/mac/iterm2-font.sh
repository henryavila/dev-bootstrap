#!/usr/bin/env bash
# Delegate to existing scripts/configure-iterm2-font.sh.
SCRIPT_REL="../scripts/configure-iterm2-font.sh"

# PostScript name the delegate writes into every profile's "Normal Font" key.
# MUST stay in sync with NF_PS_NAME in ../scripts/configure-iterm2-font.sh.
NF_PS_NAME="CaskaydiaCoveNF-Regular"

# Resolve the iTerm2 app bundle in either supported location, echoing its path.
# The delegate honours both /Applications and ~/Applications; check() must too,
# otherwise a home-installed iTerm2 (the live state on this mac) is invisible to
# the keep/skip decision and the font gets silently left unconfigured.
_iterm2_dir() {
    local c
    for c in "/Applications/iTerm.app" "$HOME/Applications/iTerm.app"; do
        if [[ -d "$c" ]]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

# Content sentinel (sudo-free): true iff at least one configured iTerm2 profile
# already has its "Normal Font" set to the Nerd Font the delegate installs.
# /usr/libexec/PlistBuddy reads the user's own prefs plist without sudo, so this
# stays compatible with the menu scanner (which stubs sudo).
_iterm2_font_set() {
    local plist="$HOME/Library/Preferences/com.googlecode.iterm2.plist"
    [[ -f "$plist" ]] || return 1
    [[ -x /usr/libexec/PlistBuddy ]] || return 1
    local i=0 cur
    # Probe profiles until a read fails (mirrors the delegate's count loop).
    while cur="$(/usr/libexec/PlistBuddy -c "Print :New\ Bookmarks:$i:Normal\ Font" "$plist" 2>/dev/null)"; do
        case "$cur" in
            *"$NF_PS_NAME"*) return 0 ;;
        esac
        i=$((i + 1))
    done
    return 1
}

check() {
    # iTerm2 not installed (neither location) → nothing to configure → pass.
    _iterm2_dir >/dev/null || return 0
    # Installed: keep only when the font is actually applied (content sentinel).
    # A bare existence check here was the audit's filesystem false-keep: with
    # iTerm2 present but the font never set, the old `[[ -d /Applications/... ]]`
    # branch (or a dangling plist) let the engine skip install() forever.
    _iterm2_font_set || return 1
    return 0
}

install() {
    _iterm2_dir >/dev/null || return 0
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -x "$here/$SCRIPT_REL" ]]; then
        bash "$here/$SCRIPT_REL" \
            || echo "[iterm2-font] config failed (non-fatal)" >&2
    fi
}

verify() {
    # Inherit check()'s content sentinel so post-install + the --repair sweep
    # assert the font is truly applied (was previously an unconditional pass,
    # which validated nothing). Safe on a healthy machine: a configured profile
    # makes both check() and verify() return 0 → keep, no spurious repair.
    check
}

repair() {
    # The delegate is idempotent and non-destructive (only swaps the font family,
    # preserves size, never kills iTerm2 — see its design notes), so re-running
    # install() is the safe auto-repair the engine --repair sweep uses when the
    # content sentinel reports the font missing.
    install
}

rollback() {
    :
}
