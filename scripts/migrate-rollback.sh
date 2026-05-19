#!/usr/bin/env bash
# scripts/migrate-rollback.sh — restore system to pre-migration state.
# See spec §7.5 for full contract + scope limits.
#
# Restores: marker files from .mesh-migrate backups, git branch in workstation
# repo, releases bridge lock.
# Does NOT restore: packages installed by setup.sh, deploys (additive — engine
# is idempotent F-A5 so re-running is safe).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."

SNAP_DIR="$HOME/.local/state/dev-bootstrap/snapshots/$(hostname)-pre-migration"
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

# 3. Release lock
rm -f "$HOME/.local/state/dev-bootstrap/migration.lock"

echo "==> Rollback complete. System restored to pre-migration state."
echo "    Snapshot preserved at $SNAP_DIR for forensic analysis."
echo "    Re-run migration only after diagnosing the failure."
