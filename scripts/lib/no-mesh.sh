#!/usr/bin/env bash
# shellcheck shell=bash
# no-mesh.sh — catalog filter for --no-mesh (MESH_NO_MESH=1).
# Source-only. Drops bundles whose membership is mesh; topics with no remaining
# bundles emit no rows and therefore disappear from the catalog.
#
# The filter is data-driven (`membership: mesh`). Callers must not hardcode a
# bundle-name denylist in the TUI or here.

# True when --no-mesh is active (exported by setup.sh / mesh menu).
no_mesh_active() {
    [[ "${MESH_NO_MESH:-0}" == "1" ]]
}

# Return 0 when this bundle should be omitted from the catalog.
# $1 = membership scalar from yaml-parse (BUNDLE_N_MEMBERSHIP), may be empty.
no_mesh_omit_bundle() {
    local membership="${1:-}"
    no_mesh_active || return 1
    [[ "$membership" == "mesh" ]]
}

# stdin:  topic<TAB>bundle<TAB>membership
# stdout: topic<TAB>bundle for kept rows. Empty topics are omitted.
no_mesh_filter_records() {
    local topic bundle membership
    while IFS=$'\t' read -r topic bundle membership || [[ -n "${topic:-}" ]]; do
        [[ -n "$topic" ]] || continue
        no_mesh_omit_bundle "$membership" && continue
        printf '%s\t%s\n' "$topic" "$bundle"
    done
}
