#!/usr/bin/env bash
# diagnose-wsl-interop.sh — pinpoint why `powershell.exe` / `pwsh.exe`
# isn't reachable from WSL, which blocks the Windows CA import step
# (Chrome/Edge on Windows won't trust *.localhost HTTPS without it).
#
# Run this manually when 60-laravel-stack prints the "Windows CA import
# skipped" critical follow-up. It checks 6 points in order and prints
# a one-line diagnosis with the most probable fix at the end.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../../lib/log.sh" 2>/dev/null || {
    ok()   { printf "✓ %s\n" "$*"; }
    info() { printf "→ %s\n" "$*"; }
    warn() { printf "! %s\n" "$*" >&2; }
    fail() { printf "✗ %s\n" "$*" >&2; }
}

banner() {
    printf '\n── %s ──\n' "$1"
}

# Summary tracking: first check that fails points at the root cause.
FIRST_FAIL=""
record_fail() {
    [[ -z "$FIRST_FAIL" ]] && FIRST_FAIL="$1"
}

# ─── 1. Are we actually in WSL? ───────────────────────────────────────
banner "1. Is this WSL?"
if grep -qi microsoft /proc/version 2>/dev/null; then
    ok "kernel identifies as WSL: $(uname -r)"
else
    fail "not running under WSL — nothing to diagnose here"
    exit 1
fi

# WSL1 vs WSL2 matters for interop: WSL1's /mnt/c is a real mount,
# WSL2's is a 9P server that can break independently.
if [[ -f /proc/wsl/version ]]; then
    ok "WSL version file present: /proc/wsl/version"
elif [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ -n "${WSL_INTEROP:-}" ]]; then
    ok "WSL env vars set: WSL_DISTRO_NAME=${WSL_DISTRO_NAME:-<unset>} WSL_INTEROP=${WSL_INTEROP:-<unset>}"
fi

# ─── 2. /mnt/c mount health ───────────────────────────────────────────
banner "2. /mnt/c mount"
if ls -d /mnt/c >/dev/null 2>&1; then
    ok "/mnt/c accessible"
    if ls /mnt/c/Windows/System32/ >/dev/null 2>&1; then
        ok "/mnt/c/Windows/System32 listable (9P responding)"
    else
        fail "/mnt/c/Windows/System32 NOT listable — 9P server side appears broken"
        record_fail "mnt-c-9p-broken"
    fi
else
    fail "/mnt/c inaccessible: $(ls -d /mnt/c 2>&1 | head -1)"
    record_fail "mnt-c-unavailable"
fi

# ─── 3. binfmt_misc WSLInterop registration ──────────────────────────
banner "3. binfmt_misc WSLInterop"
# Interop (running Windows .exe from inside WSL) relies on binfmt_misc
# registering the WSLInterop handler at boot. WSL usually registers it
# at startup via /init, but a broken systemd unit, a wsl.conf edit with
# a syntax error, or a half-initialized session can skip it.
if [[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]]; then
    if grep -q '^enabled' /proc/sys/fs/binfmt_misc/WSLInterop; then
        ok "WSLInterop registered and enabled"
    else
        fail "WSLInterop registered but NOT enabled"
        record_fail "binfmt-disabled"
    fi
elif [[ -f /proc/sys/fs/binfmt_misc/WSLInterop-late ]]; then
    ok "WSLInterop-late registered (systemd-based WSL — newer pattern)"
else
    fail "binfmt WSLInterop NOT registered in /proc/sys/fs/binfmt_misc"
    record_fail "binfmt-missing"
fi

# ─── 4. WSL_INTEROP env var ───────────────────────────────────────────
banner "4. WSL_INTEROP socket"
if [[ -n "${WSL_INTEROP:-}" ]] && [[ -S "$WSL_INTEROP" ]]; then
    ok "WSL_INTEROP socket exists: $WSL_INTEROP"
else
    fail "WSL_INTEROP socket missing: ${WSL_INTEROP:-<unset>}"
    record_fail "interop-socket-missing"
fi

# ─── 5. /etc/wsl.conf — any interop disable flags? ───────────────────
banner "5. /etc/wsl.conf flags"
if [[ -f /etc/wsl.conf ]]; then
    ok "/etc/wsl.conf exists"
    interop_enabled="$(grep -E '^\s*enabled' /etc/wsl.conf 2>/dev/null | head -1)"
    path_append="$(grep -E '^\s*appendWindowsPath' /etc/wsl.conf 2>/dev/null | head -1)"
    if [[ -n "$interop_enabled" ]]; then
        info "interop explicit setting: $interop_enabled"
        [[ "$interop_enabled" =~ false ]] && {
            fail "interop disabled in /etc/wsl.conf"
            record_fail "wsl-conf-interop-false"
        }
    fi
    if [[ -n "$path_append" ]]; then
        info "PATH append setting: $path_append"
    fi
else
    info "/etc/wsl.conf not present (defaults apply)"
fi

# ─── 6. Can we actually invoke powershell.exe? ───────────────────────
banner "6. powershell.exe execution"
PWSH_CANDIDATES=(
    powershell.exe
    pwsh.exe
    "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
    "/mnt/c/Program Files/PowerShell/7/pwsh.exe"
)

PWSH_FOUND=""
PWSH_RUNS=""
for cand in "${PWSH_CANDIDATES[@]}"; do
    # Can we locate it?
    if command -v "$cand" >/dev/null 2>&1 || [[ -x "$cand" ]]; then
        PWSH_FOUND="$cand"
        # Can we actually run it?
        if out="$("$cand" -NoProfile -Command 'Write-Output ok' 2>&1)" && [[ "$out" == "ok"* ]]; then
            PWSH_RUNS="$cand"
            break
        fi
    fi
done

if [[ -n "$PWSH_RUNS" ]]; then
    ok "can locate AND execute: $PWSH_RUNS"
elif [[ -n "$PWSH_FOUND" ]]; then
    fail "found $PWSH_FOUND but execution failed"
    record_fail "pwsh-found-but-cannot-run"
else
    fail "no powershell.exe or pwsh.exe found in PATH or standard Windows paths"
    record_fail "pwsh-not-found"
fi

# ─── Diagnosis ────────────────────────────────────────────────────────
banner "Diagnosis"

case "$FIRST_FAIL" in
    "")
        ok "All checks passed — interop looks healthy. If the bootstrap still"
        ok "refuses to do the Windows CA import, re-run:"
        ok "  ONLY_TOPICS=60-laravel-stack bash ~/dev-bootstrap/bootstrap.sh"
        ;;
    "mnt-c-9p-broken"|"mnt-c-unavailable")
        fail "The /mnt/c 9P mount is broken in this WSL session."
        fail "Most likely fix (resets the plan9 server WSL uses to reach Windows):"
        fail "  From a Windows PowerShell or cmd (NOT from inside WSL):"
        fail "    wsl --shutdown"
        fail "  Reopen your WSL terminal. /mnt/c should work again."
        ;;
    "binfmt-missing"|"binfmt-disabled")
        fail "binfmt_misc WSLInterop is not registered — Windows .exe calls"
        fail "from Linux side will always fall through."
        fail "Fixes in order of preference:"
        fail "  1. wsl --shutdown (from Windows), reopen WSL — usually re-registers."
        fail "  2. Ensure /etc/wsl.conf doesn't disable interop:"
        fail "       [interop]"
        fail "       enabled = true"
        fail "       appendWindowsPath = true"
        fail "  3. If systemd is enabled: check the binfmt-support unit:"
        fail "       systemctl status systemd-binfmt.service"
        ;;
    "interop-socket-missing")
        fail "WSL_INTEROP socket missing — init didn't create /run/WSL/<pid>_interop."
        fail "Fix: wsl --shutdown from Windows, reopen WSL."
        ;;
    "wsl-conf-interop-false")
        fail "/etc/wsl.conf explicitly disables interop."
        fail "Edit the file, set [interop] enabled = true, then wsl --shutdown."
        ;;
    "pwsh-found-but-cannot-run")
        fail "powershell.exe is on disk but cannot execute via interop."
        fail "This usually means binfmt_misc or the interop socket is broken."
        fail "Fix: wsl --shutdown from Windows PowerShell, then reopen WSL."
        ;;
    "pwsh-not-found")
        fail "PATH doesn't include Windows System32 AND /mnt/c abs paths don't work."
        fail "Two possible causes:"
        fail "  - /etc/wsl.conf has 'appendWindowsPath = false' — either remove that,"
        fail "    or set the paths manually before running the bootstrap."
        fail "  - /mnt/c is broken — see 'mnt-c-9p-broken' fix above."
        ;;
esac

# Exit non-zero when anything failed, so callers (CI, etc.) can detect it.
[[ -z "$FIRST_FAIL" ]] && exit 0 || exit 1
