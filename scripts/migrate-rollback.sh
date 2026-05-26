#!/usr/bin/env bash
# scripts/migrate-rollback.sh — restore system to pre-migration state.
# See spec §7.5 for full contract + scope limits.
#
# Restores: marker files from .mesh-migrate backups, git branch in workstation
# repo, releases bridge lock.
# Does NOT restore: packages installed by setup.sh, deploys (additive — engine
# is idempotent F-A5 so re-running is safe).
#
# Flags:
#   --force-stale-lock   delete the bridge lock even if it claims an active
#                        bridge (pid alive on this host). Use when the
#                        bridge process is hung and cannot be killed
#                        cleanly. Without this flag the rollback refuses
#                        with rc=2 to avoid racing a concurrent bridge.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."

FORCE_STALE_LOCK=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force-stale-lock) FORCE_STALE_LOCK=1 ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 64 ;;
    esac
    shift
done

SNAP_DIR="$HOME/.local/state/mesh-workstation/snapshots/$(hostname)-pre-migration"
if [[ ! -d "$SNAP_DIR" ]]; then
    echo "ERROR: no snapshot found at $SNAP_DIR — cannot rollback." >&2
    echo "(Did migrate-to-engine.sh ever run on this machine?)" >&2
    exit 1
fi

# CP4 chunk A3 finding F-003 (critical): preflight ALL required snapshot
# files BEFORE mutating .mesh-migrate backups or restoring markers. The
# previous ordering restored markers + deleted .mesh-migrate, then read
# git metadata via `cat` under set -e — when git metadata was absent
# (and the current v0 bridge never writes it), the script aborted with
# the marker audit trail already gone. Symmetric preflight + fail-loud
# preserves backups for forensic inspection.
required=(
    "$SNAP_DIR/git-branch-before-migration.txt"
    "$SNAP_DIR/git-head-before-migration.txt"
)
missing=()
for f in "${required[@]}"; do
    [[ -r "$f" ]] || missing+=("$f")
done
if (( ${#missing[@]} > 0 )); then
    echo "ERROR: rollback aborted — required snapshot file(s) missing:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    echo "" >&2
    echo "(.mesh-migrate marker backups preserved for forensic inspection." >&2
    echo " Inspect $SNAP_DIR/ to understand what state the bridge captured" >&2
    echo " before this rollback was attempted.)" >&2
    exit 2
fi

# 1. Restore marker files from .mesh-migrate backups
for f in ~/.ssh/authorized_keys ~/.bashrc ~/.zshrc ~/.tmux.conf ~/.gitconfig; do
    if [[ -f "$f.mesh-migrate" ]]; then
        cp "$f.mesh-migrate" "$f"
        rm "$f.mesh-migrate"
        echo "  restored: $f"
    fi
done

# 2. Restore git branch in workstation repo
prev_branch="$(cat "$SNAP_DIR/git-branch-before-migration.txt")"
prev_head="$(cat "$SNAP_DIR/git-head-before-migration.txt")"
if [[ "$prev_branch" == "(detached)" ]]; then
    git checkout "$prev_head"
else
    git checkout "$prev_branch"
fi
echo "  restored git: $prev_branch @ $prev_head"

# 3. Release lock (A3-F-005: validate ownership before deletion).
#    Bridge step 1 writes pid + host + started into the lock file. We
#    only safely delete a lock whose claimed owner is dead OR runs on a
#    different host. An active lock on this host means a bridge is mid-
#    migration; refuse without --force-stale-lock so two unrelated
#    operators don't accidentally race each other.
LOCK="$HOME/.local/state/mesh-workstation/migration.lock"
if [[ -f "$LOCK" ]]; then
    lock_pid=""; lock_host=""
    if [[ -s "$LOCK" ]]; then
        while IFS='=' read -r key value; do
            case "$key" in
                pid)  lock_pid="$value" ;;
                host) lock_host="$value" ;;
            esac
        done < "$LOCK"
    fi
    current_host=$(hostname)
    if [[ -z "$lock_pid" || -z "$lock_host" ]]; then
        rm -f "$LOCK"
        echo "  released stale lock (no ownership metadata)"
    elif [[ "$lock_host" != "$current_host" ]]; then
        rm -f "$LOCK"
        echo "  released stale lock (host=$lock_host != current=$current_host)"
    elif kill -0 "$lock_pid" 2>/dev/null; then
        if [[ "$FORCE_STALE_LOCK" == "1" ]]; then
            rm -f "$LOCK"
            echo "  released ACTIVE lock via --force-stale-lock (pid=$lock_pid was running)" >&2
        else
            echo "ERROR: migration lock at $LOCK is held by an active process." >&2
            echo "       pid=$lock_pid host=$lock_host" >&2
            echo "       Pass --force-stale-lock to override (e.g., when the bridge" >&2
            echo "       process is hung and cannot be killed cleanly)." >&2
            exit 2
        fi
    else
        rm -f "$LOCK"
        echo "  released stale lock (pid=$lock_pid no longer running)"
    fi
fi

echo "==> Rollback complete. System restored to pre-migration state."
echo "    Snapshot preserved at $SNAP_DIR for forensic analysis."
echo "    Re-run migration only after diagnosing the failure."
