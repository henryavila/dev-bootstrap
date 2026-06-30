# shellcheck shell=bash
# scripts/lib/ai-pinned.sh — manually-pinned project manifest for `mesh ai`.
# Source-only (no top-level execution).
#
# ai-discover.sh scans AI_ROOTS one level deep for `.git` repos (automatic).
# THIS lib reads an EXPLICIT, versioned manifest of dirs the user wants always
# present — deep subdirs, non-git folders, host-specific paths — and the runner
# merges it with discovery. It complements; it does not replace.
#
# Path: $MESH_AI_PINNED (default $MESH_IDENTITY_DIR/shell/ai-pinned.list — the
# file lives in mesh-identity and is synced across machines; only its READER
# lives here in mesh-workstation, mirroring AI_ROOTS / syncthing-mesh.yaml).
#
# Line format:  <name>|<path[:alt-path[:...]]>
#   • Engine picks the FIRST existing alt, so one file serves mac/WSL/crc.
#   • '~' expands to $HOME per alt; '$VAR' is NOT expanded (kept literal).
#   • Non-git dirs are allowed — pinned is the explicit override of the `.git`
#     gate that ai_discover enforces.
#   • Reserved chars in a path: | (field)   : (alternate)   # (comment).
#   • A line with no `|`, or whose every alt is missing on this host, is
#     skipped SILENTLY (never an error) — same contract as ai_roots.

# Print `name<TAB>path` for each pinned entry resolvable on this host.
# A missing manifest, or entries whose paths don't exist here, contribute
# nothing and never error.
ai_pinned() {
    local file="${MESH_AI_PINNED:-${MESH_IDENTITY_DIR:-$HOME/mesh-identity}/shell/ai-pinned.list}"
    [[ -r "$file" ]] || return 0
    local line name pathfield cand picked
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"                                   # strip inline comment
        line="${line#"${line%%[![:space:]]*}"}"              # ltrim
        line="${line%"${line##*[![:space:]]}"}"              # rtrim
        [[ -z "$line" ]] && continue
        name="${line%%|*}"
        pathfield="${line#*|}"
        [[ "$name" == "$pathfield" ]] && continue            # no '|' → malformed
        [[ -z "$name" ]] && continue
        picked=""
        while IFS= read -r cand || [[ -n "$cand" ]]; do
            [[ -z "$cand" ]] && continue
            cand="${cand/#\~/$HOME}"
            if [[ -e "$cand" ]]; then picked="$cand"; break; fi
        done < <(printf '%s' "$pathfield" | tr ':' '\n')
        [[ -n "$picked" ]] || continue
        printf '%s\t%s\n' "$name" "$picked"
    done < "$file"
}
