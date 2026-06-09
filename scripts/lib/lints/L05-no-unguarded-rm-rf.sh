#!/usr/bin/env bash
# L05 — `rm -rf` must be guarded. We accept the following safe patterns:
#   1. `trap 'rm -rf …' EXIT/RETURN` — process-bounded cleanup trap.
#   2. `rm -rf "$VAR"` where `$VAR` is a recognized temp/scope name
#      (tmp, TMP, tmpdir, tmpbin, tmpmeta, staging, target, build, dist,
#      cache_dir, cache, dir, OUT, SNAPSHOT).
#   3. Quoted `info "would rm -rf …"` log lines (dry-run output).
#
# Other forms — bare `rm -rf <literal>` or `rm -rf $unguarded_var` — are
# flagged for human review. Phase 5 emerged item: the rule is heuristic;
# adding to the allowlist as new safe variables emerge is expected.
#
# Spec: §C21. Phase 5 emerged item.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

candidates=$(grep -rnE '^[^#]*\brm[[:space:]]+-rf?\b' \
    --include='*.sh' --include='*.zsh' \
    --exclude-dir=tests --exclude-dir=.git --exclude-dir=archive \
    "$ROOT/scripts" "$ROOT/topics" "$ROOT/bin" 2>/dev/null || true)

[[ -z "$candidates" ]] && exit 0

# Allowlist filters.
safe_vars='(tmp|TMP|tmpdir|tmpbin|tmpmeta|staging|target|build|dist|cache_dir|cache|dir|OUT|SNAPSHOT)'
hits=$(printf '%s\n' "$candidates" \
    | grep -vE "trap[[:space:]]+[\"'][^\"']*\brm[[:space:]]+-rf?\b" \
    | grep -vE "\brm[[:space:]]+-rf?[[:space:]]+\"?\\\$\\{?$safe_vars\\b" \
    | grep -vE 'info\b.*"would rm -rf' \
    || true)

if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | sed "s|^$ROOT/|L05: |; s|$| (guard with trap or allowlisted \$VAR)|"
    exit 1
fi
exit 0
