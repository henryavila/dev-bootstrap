#!/usr/bin/env bash
# configure-iterm2-font.sh — set CaskaydiaCove Nerd Font on all iTerm2 profiles.
#
# Called by install.mac.sh after 20-terminal-ux brew packages (including
# font-caskaydia-cove-nerd-font) are installed. Safe to run standalone:
#
#   bash topics/20-terminal-ux/scripts/configure-iterm2-font.sh
#
# Design notes:
#   - Uses /usr/libexec/PlistBuddy for surgical array edits. `defaults write`
#     can't partial-update a specific entry inside "New Bookmarks" (the
#     profile array); it replaces the whole array.
#   - Preserves each profile's current font SIZE; only swaps the family.
#     If the current value isn't "<family> <size>" format, defaults to 14.
#   - Also flips "Use Non-ASCII Font" to false per profile, so the Nerd Font
#     handles all glyphs (the non-ASCII fallback was why icon positions like
#     eza folder glyphs rendered as "?" even after the font was installed).
#   - Idempotent: a profile whose Normal Font already contains the PostScript
#     name below is left alone.
#   - iTerm2 caches prefs in memory. If running, user must fully quit (⌘Q in
#     iTerm2) + relaunch for the change to take effect. Script warns but
#     never kills iTerm2 — destructive without explicit consent.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../../lib/log.sh"

# ─── PostScript name of CaskaydiaCove Nerd Font (monospace variant). ───
# Verified on a machine with the brew cask installed — the .ttf files ship
# with this internal PostScript name, which is what iTerm2 expects in the
# "Normal Font" key (format: "<PSName> <size>"). NOT "Propo" (proportional)
# which breaks alignment of ls/tables/code in a terminal.
NF_PS_NAME="CaskaydiaCoveNF-Regular"

# ─── Detect iTerm2 install ───
iterm_app=""
for candidate in "/Applications/iTerm.app" "$HOME/Applications/iTerm.app"; do
    [ -d "$candidate" ] && iterm_app="$candidate" && break
done
if [ -z "$iterm_app" ]; then
    info "iTerm2 not installed — skipping font config"
    exit 0
fi

plist="$HOME/Library/Preferences/com.googlecode.iterm2.plist"
if [ ! -f "$plist" ]; then
    info "iTerm2 has no preferences file yet — launch it once then re-run"
    exit 0
fi

# ─── Count profiles (probe until a read fails) ───
profile_count=0
while /usr/libexec/PlistBuddy -c "Print :New\ Bookmarks:$profile_count:Normal\ Font" "$plist" >/dev/null 2>&1; do
    profile_count=$((profile_count + 1))
done
if [ "$profile_count" -eq 0 ]; then
    warn "iTerm2 has no configured profiles — skipping"
    exit 0
fi

# ─── Apply to each profile ───
changed=0
for i in $(seq 0 $((profile_count - 1))); do
    current="$(/usr/libexec/PlistBuddy -c "Print :New\ Bookmarks:$i:Normal\ Font" "$plist" 2>/dev/null || echo "")"
    if [[ "$current" == *"$NF_PS_NAME"* ]]; then
        continue
    fi

    # Preserve size if the existing value ended in a number; default to 14.
    size="${current##* }"
    [[ "$size" =~ ^[0-9]+$ ]] || size=14
    new_font="$NF_PS_NAME $size"

    /usr/libexec/PlistBuddy -c "Set :New\ Bookmarks:$i:Normal\ Font $new_font" "$plist" 2>/dev/null

    # Disable "Use Non-ASCII Font" — set or add depending on whether the key exists.
    if ! /usr/libexec/PlistBuddy -c "Set :New\ Bookmarks:$i:Use\ Non-ASCII\ Font false" "$plist" 2>/dev/null; then
        /usr/libexec/PlistBuddy -c "Add :New\ Bookmarks:$i:Use\ Non-ASCII\ Font bool false" "$plist" 2>/dev/null || true
    fi

    profile_name="$(/usr/libexec/PlistBuddy -c "Print :New\ Bookmarks:$i:Name" "$plist" 2>/dev/null || echo "profile $i")"
    ok "iTerm2: profile '$profile_name' → $new_font"
    changed=1
done

if [ "$changed" -eq 0 ]; then
    ok "iTerm2 profiles already using $NF_PS_NAME — no change"
    exit 0
fi

# ─── Cache reload ───
iterm_running=0
if pgrep -x iTerm2 >/dev/null 2>&1; then
    iterm_running=1
fi

if [ "$iterm_running" -eq 1 ]; then
    warn "iTerm2 is running — prefs are cached in memory and will overwrite our edit on quit."
    warn "Fully quit iTerm2 (⌘Q inside iTerm2), then relaunch, for changes to take effect."
else
    # Not running: bounce cfprefsd so the next launch reads fresh from disk.
    killall cfprefsd 2>/dev/null || true
    ok "font applied; launch iTerm2 to see the change"
fi
