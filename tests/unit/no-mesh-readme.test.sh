#!/usr/bin/env bash
# F3 T-001 — README documents --no-mesh; does not present ONLY_TOPICS as a live
# v2 selection API; SPEC records membership mesh and MESH_NO_MESH.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

README="$WS/README.md"
README_PT="$WS/README.pt-BR.md"
SPEC="$WS/docs/SPEC.md"

assert_file_exists "$README" "README.md exists"
assert_file_exists "$README_PT" "README.pt-BR.md exists"
assert_file_exists "$SPEC" "docs/SPEC.md exists"

assert_file_contains "$README" 'bash setup.sh --no-mesh' \
    "README documents bash setup.sh --no-mesh"
assert_file_contains "$README" 'mesh menu --no-mesh' \
    "README documents mesh menu --no-mesh"
assert_file_contains "$README" 'MESH_NO_MESH' \
    "README mentions MESH_NO_MESH"

assert_file_contains "$README_PT" 'bash setup.sh --no-mesh' \
    "README.pt-BR documents bash setup.sh --no-mesh"
assert_file_contains "$README_PT" 'mesh menu --no-mesh' \
    "README.pt-BR documents mesh menu --no-mesh"

# ONLY_TOPICS must not appear as a live working example (assignment form).
for f in "$README" "$README_PT" "$SPEC"; do
    label="$(basename "$f")"
    if grep -nE '^\s*ONLY_TOPICS=' "$f" >/dev/null 2>&1; then
        fail "$label must not present ONLY_TOPICS=… as a live example"
        grep -nE '^\s*ONLY_TOPICS=' "$f" | sed 's/^/      /' >&2
    else
        pass "$label has no live ONLY_TOPICS=… assignment examples"
    fi
done
assert_file_contains "$README" 'Legacy / dead' \
    "README marks ONLY_TOPICS as legacy/dead in v2"
assert_file_contains "$README_PT" 'Legacy / dead' \
    "README.pt-BR marks ONLY_TOPICS as legacy/dead in v2"
assert_file_contains "$SPEC" 'Legacy / dead' \
    "SPEC marks ONLY_TOPICS as legacy/dead in v2"

assert_file_contains "$SPEC" 'membership: mesh' \
    "SPEC records membership: mesh"
assert_file_contains "$SPEC" 'MESH_NO_MESH' \
    "SPEC records MESH_NO_MESH"
# grep treats a pattern starting with -- as options; match without the dashes.
assert_file_contains "$SPEC" 'no-mesh' \
    "SPEC documents --no-mesh"

summary
