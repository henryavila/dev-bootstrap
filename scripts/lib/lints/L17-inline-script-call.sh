#!/usr/bin/env bash
# L17 — inline `bash $HERE/scripts/install-*.sh` calls are migration candidates.
#
# Each hit identifies an installable that should become a discrete
# `items.yaml` entry (typically `type: custom` with a contract-shaped
# script) so the future menu can expose it as its own toggle. See the
# topic-engine-migration initiative for the inventory + rationale.
#
# ADVISORY MODE: this lint prints findings but ALWAYS exits 0, so it
# surfaces the backlog without breaking CI. When the migration backlog
# reaches zero, flip the exit at the bottom to `exit "$count"`.
#
# Spec: §C18 (escape hatch `type: custom`) + §C13/C16 architectural intent
# ("every installable discrete"). Phase 6 follow-up; tracked under
# .atomic-skills/initiatives/topic-engine-migration.md.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

[[ -d "$ROOT/topics" ]] || exit 0

hits=$(grep -rnE '^[^#]*bash[[:space:]]+"?\$HERE/scripts/install-[A-Za-z0-9._-]+\.sh' \
    --include='install.sh' --include='install.mac.sh' --include='install.wsl.sh' \
    --exclude-dir=tests --exclude-dir=.git --exclude-dir=archive \
    "$ROOT/topics" 2>/dev/null || true)

if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" \
        | sed "s|^$ROOT/|L17 (advisory): |; s|$| (migrate to items.yaml type:custom — see topic-engine-migration initiative)|"
fi

exit 0
