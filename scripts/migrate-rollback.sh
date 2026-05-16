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
