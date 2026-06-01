#!/usr/bin/env bash
# L20 — every topics/*/manifest.yaml v2 must pass the schema validator.
# Wraps scripts/lib/validate-manifest.sh so manifest correctness is enforced in
# pre-commit (via `mesh lint`) alongside the architectural invariants.
#
# Default (non-strict): a requires_bundles forward-ref to a topic not yet
# migrated is a warning, not an error — the F9.6 migration is mid-flight and
# topics land one at a time. Hard rule violations (missing fields, dup names,
# cycles, bad when:/derive_from) fail the lint.
#
# Spec: docs/2026-05-28-mesh-manifest-v2-spec.md §8.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

shopt -s nullglob
manifests=("$ROOT"/topics/*/manifest.yaml)
shopt -u nullglob

# No v2 manifests yet → nothing to validate (clean).
[[ ${#manifests[@]} -eq 0 ]] && exit 0

out="$(bash "$ROOT/scripts/lib/validate-manifest.sh" 2>&1)"
rc=$?
if [[ $rc -ne 0 ]]; then
    printf '%s\n' "$out" | grep '^ERROR' | sed 's/^ERROR  /L20: /'
    exit 1
fi
exit 0
