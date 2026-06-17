#!/usr/bin/env bash
# scripts/lib/external-brew-mount.sh — detect (and heal) the macOS
# "external-brew mount disambiguation" failure.
#
# Failure mode (incident 2026-05-02; recurred 2026-06-16 after a macOS update
# regenerated the daemon plists): Homebrew's prefix lives on an external
# /Volumes/* APFS volume. A system LaunchDaemon (php/nginx/dnsmasq) with
# RunAtLoad + a Standard*Path INSIDE that volume is loaded by launchd at early
# boot, BEFORE the external disk mounts. Opening that log path O_CREAT makes
# launchd mkdir -p the parent on the ROOTFS, creating a phantom directory at
# the volume's canonical mount point (/Volumes/<Name>). When the real disk
# finally mounts, diskarbitrationd finds the name taken and disambiguates to
# "/Volumes/<Name> 1", breaking every absolute path into the volume.
#
# This lib is GENERIC and side-effect-free to source:
#   * macOS only         — every entry point is a clean no-op on other OSes.
#   * external-brew only — only acts when `brew --prefix` is under /Volumes/*.
#   * NEVER hardcodes a volume name — the canonical name is read from
#     `diskutil info` of the mounted volume, so it works for ANY disk name
#     (External, Backup, "My SSD", …) on any fork's machine.
#   * base-system tools only (diskutil, plutil, /usr/libexec/PlistBuddy,
#     launchctl, lsof) — NO brew dependency, so it runs in the degraded state
#     where brew's own PATH points at the phantom and is broken.
#
# Public API (all safe to call on any platform):
#   ebm_supported       rc0 only where the failure mode can occur (macOS)
#   ebm_detect          populate EBM_* globals; rc0 iff a collision is PRESENT
#   ebm_report_line     human one-liner describing the detected collision
#   ebm_heal            corrective recovery (re-harden + de-phantom + remount)
#
# After ebm_detect rc0, these globals are set:
#   EBM_PREFIX          brew prefix, e.g. "/Volumes/External 1/homebrew"
#   EBM_ACTUAL_MNT      where the volume is mounted now, e.g. "/Volumes/External 1"
#   EBM_VOLUME_NAME     diskutil VolumeName, e.g. "External"
#   EBM_CANONICAL_MNT   where it SHOULD mount, e.g. "/Volumes/External"
#   EBM_DEVICE          BSD device id for remount, e.g. "disk7s1"
#   EBM_PHANTOM         canonical path IFF it is a phantom dir (else "")
#
# Test injection (all default to production values):
#   EBM_FORCE_SUPPORTED=1     bypass the uname gate (run logic off-mac)
#   EBM_BREW_PREFIX_OVERRIDE  use this prefix instead of probing brew
#   EBM_DISKUTIL              diskutil binary (stub in tests)
#   EBM_VOLUMES_DIR           /Volumes root (temp dir in tests)
#   EBM_NO_SUDO=1             never escalate (tests / unprivileged probe)

# Resolve this lib's directory so we can find sibling scripts (detect-brew.sh)
# and the repo root (the topic hardening script) regardless of caller cwd.
_ebm_lib_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }
_ebm_repo_root() { cd "$(_ebm_lib_dir)/../.." && pwd; }

ebm_supported() {
    [[ "${EBM_FORCE_SUPPORTED:-0}" == "1" ]] && return 0
    [[ "$(uname -s)" == "Darwin" ]]
}

# Run a command with root privileges only when needed and allowed.
ebm_priv() {
    if [[ "${EBM_NO_SUDO:-0}" == "1" || "$(id -u)" == "0" ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Resolve brew prefix WITHOUT trusting $PATH (it may point at the phantom in the
# degraded state). detect-brew.sh globs /Volumes/<name>*/homebrew so it finds
# the real brew even after disambiguation. Run it as a subprocess: it uses
# `set -e` + `exit`, which would kill our shell if sourced.
ebm_brew_prefix() {
    if [[ -n "${EBM_BREW_PREFIX_OVERRIDE:-}" ]]; then
        printf '%s' "$EBM_BREW_PREFIX_OVERRIDE"
        return 0
    fi
    local detect out
    detect="$(_ebm_lib_dir)/detect-brew.sh"
    [[ -f "$detect" ]] || return 1
    out="$(bash "$detect" 2>/dev/null)" || return 1
    # out is "BREW_BIN=...\nBREW_PREFIX=...". Pull BREW_PREFIX without eval.
    local line
    while IFS= read -r line; do
        case "$line" in
            BREW_PREFIX=*)
                # Value is %q-quoted by detect-brew; eval just this assignment.
                eval "$line"
                printf '%s' "$BREW_PREFIX"
                return 0
                ;;
        esac
    done <<< "$out"
    return 1
}

# Read one field from `diskutil info -plist <mnt>`. Empty + rc1 if <mnt> is not
# a mounted volume (plain dirs make diskutil exit non-zero). plutil parses the
# plist robustly (values with spaces, e.g. "/Volumes/External 1").
ebm_diskutil_field() {
    local mnt="$1" key="$2" du tmp val
    du="${EBM_DISKUTIL:-diskutil}"
    tmp="$(mktemp -t ebm_di.XXXXXX)" || return 1
    if ! "$du" info -plist "$mnt" >"$tmp" 2>/dev/null; then
        rm -f "$tmp"; return 1
    fi
    val="$(plutil -extract "$key" raw -o - "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    [[ -n "$val" ]] || return 1
    printf '%s' "$val"
}

# True iff <path> is the mount point of a mounted volume (not just a directory).
ebm_is_mountpoint() {
    local p="$1" mp
    mp="$(ebm_diskutil_field "$p" MountPoint)" || return 1
    [[ "$mp" == "$p" ]]
}

ebm_detect() {
    EBM_PREFIX="" EBM_ACTUAL_MNT="" EBM_VOLUME_NAME=""
    EBM_CANONICAL_MNT="" EBM_DEVICE="" EBM_PHANTOM=""
    ebm_supported || return 1

    local prefix; prefix="$(ebm_brew_prefix)" || return 1
    [[ -n "$prefix" ]] || return 1

    local vroot="${EBM_VOLUMES_DIR:-/Volumes}"
    # external-brew only: a standard prefix (/opt/homebrew, /usr/local) is not
    # under the volumes root → nothing to heal.
    case "$prefix" in
        "$vroot"/*) : ;;
        *) return 1 ;;
    esac
    EBM_PREFIX="$prefix"

    # Mount point = volumes root + first path component (volume names may
    # contain spaces but never a slash, so the component ends at the next /).
    local rest comp
    rest="${prefix#"$vroot"/}"     # "External 1/homebrew"
    comp="${rest%%/*}"             # "External 1"
    EBM_ACTUAL_MNT="$vroot/$comp"

    # Canonical name + device come from the volume itself — never hardcoded.
    EBM_VOLUME_NAME="$(ebm_diskutil_field "$EBM_ACTUAL_MNT" VolumeName)" || return 1
    EBM_DEVICE="$(ebm_diskutil_field "$EBM_ACTUAL_MNT" DeviceIdentifier)" || true
    [[ -n "$EBM_VOLUME_NAME" ]] || return 1
    EBM_CANONICAL_MNT="$vroot/$EBM_VOLUME_NAME"

    # Already at the canonical path → no collision.
    [[ "$EBM_ACTUAL_MNT" == "$EBM_CANONICAL_MNT" ]] && return 1

    # Collision: the canonical path is occupied by a phantom directory
    # (exists, but is NOT a mounted volume).
    if [[ -d "$EBM_CANONICAL_MNT" ]] && ! ebm_is_mountpoint "$EBM_CANONICAL_MNT"; then
        EBM_PHANTOM="$EBM_CANONICAL_MNT"
    fi
    return 0
}

# Guard before `rm -rf`: a launchd phantom only ever contains directories and
# the Standard*Path *.log file(s) — nothing else, no user data. Refuse to
# delete anything that holds an unexpected file or that is itself a mount.
# Deliberately name-agnostic (does not assume "homebrew") so it stays generic.
ebm_phantom_is_safe() {
    local dir="$1" f
    [[ -n "$dir" && -d "$dir" ]] || return 1
    ebm_is_mountpoint "$dir" && return 1
    while IFS= read -r f; do
        [[ -d "$f" ]] && continue
        case "$f" in
            *.log) continue ;;
            *) return 1 ;;   # an unexpected file → not a phantom; abort
        esac
    done < <(find "$dir" -mindepth 1 2>/dev/null)
    return 0
}

# Re-run the canonical LaunchDaemon hardening (topics/<web>/mac/
# launchdaemon-hardening.sh) so the NEXT boot can't recreate the phantom.
# Runs it in a subshell with BREW_PREFIX set, isolating the topic item's
# install()/check() from this lib.
ebm_reharden() {
    local repo cand hs=""
    repo="$(_ebm_repo_root)"
    for cand in "$repo/topics/web/mac/launchdaemon-hardening.sh" "$repo"/topics/*/mac/launchdaemon-hardening.sh; do
        [[ -f "$cand" ]] && { hs="$cand"; break; }
    done
    [[ -n "$hs" ]] || { echo "[heal] hardening script not found; skipping re-harden" >&2; return 1; }
    BREW_PREFIX="$EBM_PREFIX" bash -c 'set -uo pipefail; . "$1"; install' _ "$hs"
}

ebm_report_line() {
    printf 'external-brew mount: volume %s mounted at %s (canonical: %s)%s\n' \
        "'${EBM_VOLUME_NAME}'" "'${EBM_ACTUAL_MNT}'" "'${EBM_CANONICAL_MNT}'" \
        "${EBM_PHANTOM:+ — phantom dir at $EBM_PHANTOM}"
}

# Corrective recovery. Idempotent: re-running after success detects no
# collision and returns 0. Sets EBM_REMOUNTED=1 iff it remounted the volume.
ebm_heal() {
    EBM_REMOUNTED=0
    ebm_detect || { echo "[heal] nothing to heal (mount correct / not an external-brew mac)"; return 0; }

    echo "[heal] external-brew mount collision:"
    echo "       volume '$EBM_VOLUME_NAME' is at '$EBM_ACTUAL_MNT' (should be '$EBM_CANONICAL_MNT')"
    [[ -n "$EBM_PHANTOM" ]] && echo "       phantom occupying canonical path: $EBM_PHANTOM"

    # 1. Harden the daemon plists (prevents the NEXT boot from recreating it).
    ebm_reharden || echo "[heal] WARN: re-harden reported an issue (continuing)" >&2

    # 2. Free the racy daemons' handles so the volume can be unmounted.
    local svc
    for svc in php nginx dnsmasq; do
        ebm_priv launchctl bootout "system/homebrew.mxcl.${svc}" >/dev/null 2>&1 || true
    done

    # 3. Remove the phantom (guarded) so the canonical name is free.
    if [[ -n "$EBM_PHANTOM" ]]; then
        if ebm_phantom_is_safe "$EBM_PHANTOM"; then
            # `target` is an L05-allowlisted scope name: the path was just
            # validated by ebm_phantom_is_safe (dirs + *.log only, never a
            # mount), so this rm -rf is the guarded form the lint expects.
            local target="$EBM_PHANTOM"
            ebm_priv rm -rf "$target" && echo "[heal] removed phantom $EBM_PHANTOM"
        else
            echo "[heal] ABORT: '$EBM_PHANTOM' is not a recognizable phantom (unexpected files or a mount). Not deleting." >&2
            return 1
        fi
    fi

    # 4. Remount so the volume lands at the now-free canonical path.
    [[ -n "$EBM_DEVICE" ]] || {
        echo "[heal] no device id resolved; phantom gone + plists hardened → a reboot now mounts at '$EBM_CANONICAL_MNT'."
        return 0
    }
    local du; du="${EBM_DISKUTIL:-diskutil}"
    if ! "$du" unmount "$EBM_ACTUAL_MNT" >/dev/null 2>&1; then
        # NEVER auto-enumerate holders with `lsof +D` here: it walks the entire
        # mounted tree and hangs for minutes on a large (multi-hundred-GB)
        # volume. The corrective work (phantom removed + plists hardened) is
        # already done, so a reboot is a clean, sufficient completion.
        echo "[heal] could not unmount '$EBM_ACTUAL_MNT' — it is in use (open files / a shell cwd on the volume)." >&2
        echo "[heal] The phantom is removed and the daemon plists are hardened, so a REBOOT now mounts '$EBM_VOLUME_NAME' at '$EBM_CANONICAL_MNT' and the disambiguation will not recur." >&2
        echo "[heal] To remount WITHOUT a reboot: quit apps/shells using the volume, then re-run. (List holders yourself with: lsof +D \"$EBM_ACTUAL_MNT\" — slow on large volumes.)" >&2
        return 0
    fi
    if "$du" mount "$EBM_DEVICE" >/dev/null 2>&1; then
        local now; now="$(ebm_diskutil_field "$EBM_CANONICAL_MNT" MountPoint || true)"
        if [[ "$now" == "$EBM_CANONICAL_MNT" ]]; then
            echo "[heal] ✓ remounted '$EBM_VOLUME_NAME' at '$EBM_CANONICAL_MNT'"
            EBM_REMOUNTED=1
        else
            echo "[heal] remounted, but at '$now' (expected '$EBM_CANONICAL_MNT')" >&2
            return 1
        fi
    else
        echo "[heal] unmounted but remount failed; run: $du mount $EBM_DEVICE" >&2
        return 1
    fi
    return 0
}
