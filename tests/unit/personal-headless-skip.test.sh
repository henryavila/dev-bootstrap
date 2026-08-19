#!/usr/bin/env bash
# personal/apply soft-skips under NON_INTERACTIVE without MESH_IDENTITY_REPO.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/log.sh"

# Stub identity helpers so we don't need network/gh.
export MESH_FOLLOWUP_FILE="$TMP/followup"
: > "$MESH_FOLLOWUP_FILE"
export MESH_IDENTITY_DIR="$TMP/no-such-identity"
unset MESH_IDENTITY_REPO || true
export NON_INTERACTIVE=1
export CREATE_IDENTITY_FROM_TEMPLATE=0

# Source apply.sh functions by extracting install in a controlled way:
# run check/install from a subshell with stubbed identity_ensure_repo.
stub="$TMP/apply-stub.sh"
cat > "$stub" <<'STUB'
HERE_ROOT="$1"
# shellcheck disable=SC1091
source "$HERE_ROOT/scripts/lib/log.sh"
identity_ensure_repo() { echo "UNEXPECTED identity_ensure_repo $*" >&2; return 1; }
topic_cleanup_apply() { :; }
# Paste the install() body by sourcing the real file after overriding helpers.
# shellcheck disable=SC1091
source "$HERE_ROOT/topics/personal/apply.sh"
install
STUB

set +e
out="$(bash "$stub" "$ROOT" 2>&1)"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || { echo "expected rc 0, got $rc"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -q 'skipping' || { echo "expected skip message"; echo "$out"; exit 1; }
grep -q 'critical' "$MESH_FOLLOWUP_FILE" || grep -qz 'Personal identity skipped' "$MESH_FOLLOWUP_FILE" \
  || { echo "expected followup recorded"; xxd "$MESH_FOLLOWUP_FILE" | head; exit 1; }

echo "  ✓ personal soft-skips headless without MESH_IDENTITY_REPO"
echo "OK"
