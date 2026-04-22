#!/usr/bin/env bash
# configure-windows-terminal.sh — Catppuccin Mocha + CaskaydiaCove NF on Windows Terminal.
#
# Runs under WSL. Does three things, all idempotent:
#   1. Install CaskaydiaCove Nerd Font on Windows side (via install-nerd-font.ps1)
#   2. Locate WT's settings.json (Store, Preview, or unpackaged install)
#   3. Surgical merge of templates/wt-settings-fragment.json via jq:
#        - schemes: append Catppuccin Mocha (unique_by name)
#        - profiles.defaults: shallow-merge font + colorScheme + visual tweaks
#      Never touches user profiles array, keybindings, theme, or anything else.
#
# Only runs on WSL — silent no-op on native Linux / macOS. Non-fatal on any
# error (returns 0) so a missing Windows Terminal never aborts the bootstrap.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../../lib/log.sh"

# ─── Only run on WSL ────────────────────────────────────────────────
if ! grep -qi microsoft /proc/version 2>/dev/null; then
    info "not running under WSL — skipping Windows Terminal config"
    exit 0
fi

# ─── Detect powershell.exe via interop ──────────────────────────────
PWSH=""
for cand in powershell.exe pwsh.exe; do
    if command -v "$cand" >/dev/null 2>&1; then
        PWSH="$cand"
        break
    fi
done
if [[ -z "$PWSH" ]]; then
    warn "powershell.exe not found on PATH — WSL interop may be disabled; skipping"
    exit 0
fi

# ─── Install Nerd Font (user-level, no admin) ───────────────────────
FONT_SCRIPT="$HERE/install-nerd-font.ps1"
if [[ -f "$FONT_SCRIPT" ]]; then
    info "installing CaskaydiaCove Nerd Font on Windows (user-level)"
    # wslpath: convert Linux path → Windows path so PowerShell can read it.
    win_script="$(wslpath -w "$FONT_SCRIPT")"
    if "$PWSH" -NoProfile -ExecutionPolicy Bypass -File "$win_script" 2>&1 | sed 's/^/    /'; then
        ok "Nerd Font step done"
    else
        warn "Nerd Font install returned non-zero (non-fatal)"
    fi
else
    warn "install-nerd-font.ps1 missing — font step skipped"
fi

# ─── Locate Windows Terminal settings.json ──────────────────────────
# Discover the Windows user profile via cmd.exe %USERPROFILE% (works even
# when the WSL user name differs from the Windows one).
win_userprofile="$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r\n')"
if [[ -z "$win_userprofile" ]]; then
    warn "could not read %USERPROFILE% from Windows — skipping settings.json"
    exit 0
fi

# wslpath -u expects forward slashes — cmd.exe returns backslashes, so
# convert explicitly. C:\Users\Foo → /mnt/c/Users/Foo.
win_userprofile_unix="$(wslpath -u "$win_userprofile")"

# Candidate paths in priority order (Store > Preview > Unpackaged).
candidates=(
    "$win_userprofile_unix/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json"
    "$win_userprofile_unix/AppData/Local/Packages/Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe/LocalState/settings.json"
    "$win_userprofile_unix/AppData/Local/Microsoft/Windows Terminal/settings.json"
)

SETTINGS=""
for c in "${candidates[@]}"; do
    if [[ -f "$c" ]]; then
        SETTINGS="$c"
        break
    fi
done

if [[ -z "$SETTINGS" ]]; then
    info "Windows Terminal settings.json not found (launch WT once then re-run)"
    exit 0
fi

info "using $SETTINGS"

# ─── Ensure jq is available (installed by 00-core, but verify) ──────
if ! command -v jq >/dev/null 2>&1; then
    warn "jq not found — 00-core should have installed it; skipping merge"
    exit 0
fi

FRAGMENT="$HERE/wt-settings-fragment.json"
if [[ ! -f "$FRAGMENT" ]]; then
    warn "wt-settings-fragment.json missing — skipping merge"
    exit 0
fi

# ─── Backup + surgical merge ────────────────────────────────────────
ts="$(date +%Y%m%d-%H%M%S)"
backup="${SETTINGS}.bak-${ts}"
cp "$SETTINGS" "$backup"

# jq filter:
#   .schemes      — append our scheme, dedupe by name
#   .profiles.defaults — shallow-merge (// preserves user keys)
#
# The fragment's "_comment" / "profileDefaults" keys are extracted; we
# never inject the top-level _comment into settings.json.
tmp_merged="$(mktemp)"
if jq --slurpfile frag "$FRAGMENT" '
    .schemes = (((.schemes // []) + $frag[0].schemes) | unique_by(.name))
    | .profiles = (.profiles // {})
    | .profiles.defaults = (($frag[0].profileDefaults) + (.profiles.defaults // {}))
' "$SETTINGS" > "$tmp_merged" 2>/dev/null; then
    # Diff: if no change, clean backup + exit quietly.
    if cmp -s "$tmp_merged" "$SETTINGS"; then
        rm -f "$tmp_merged" "$backup"
        ok "Windows Terminal settings.json already configured (Catppuccin + NF)"
    else
        cp "$tmp_merged" "$SETTINGS"
        rm -f "$tmp_merged"
        ok "merged Catppuccin Mocha + CaskaydiaCove NF into $SETTINGS"
        info "backup at $backup"
    fi
else
    rm -f "$tmp_merged"
    warn "jq merge failed — settings.json left unchanged; backup at $backup"
fi

ok "Windows Terminal config done"
