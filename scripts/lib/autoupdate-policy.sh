# shellcheck shell=bash
# scripts/lib/autoupdate-policy.sh — resolve the per-host autoupdate override.
#
# Two-layer opt-in (see initiative package-autoupdate): the public manifest's
# `autoupdate: true` flag sets eligibility; this per-host file (private, in
# mesh-identity) is the final say. It mirrors config/services.default.<alias>.
#
# File: $MESH_IDENTITY_DIR/config/autoupdate.default.<alias>  (test override:
# MESH_AUTOUPDATE_FILE). Line contract = the .list files:
#   - one item name per line
#   - a bare name  → DENY  (suppress a manifest-flagged item on THIS host —
#                          e.g. a corporate box that wants nothing self-updating)
#   - a `+name`    → ALLOW (opt a NON-flagged item in on this host only)
#   - blank lines + `#` comments (inline too) ignored
#
# Resolves the file into two space-padded env lists the engine consumes:
#   MESH_AUTOUPDATE_DENY   "name1 name2 …"
#   MESH_AUTOUPDATE_ALLOW  "name3 …"
# A missing alias or missing file = manifest defaults honored (both empty).

# autoupdate_policy_export — read the per-host file (via MESH_AUTOUPDATE_ALIAS +
# MESH_IDENTITY_DIR, or MESH_AUTOUPDATE_FILE) and export DENY/ALLOW. Idempotent;
# never fails the caller (a parse problem just yields manifest defaults).
autoupdate_policy_export() {
    export MESH_AUTOUPDATE_DENY="" MESH_AUTOUPDATE_ALLOW=""
    local file="${MESH_AUTOUPDATE_FILE:-}"
    if [[ -z "$file" ]]; then
        local alias="${MESH_AUTOUPDATE_ALIAS:-}"
        [[ -n "$alias" ]] || return 0
        file="${MESH_IDENTITY_DIR:-$HOME/mesh-identity}/config/autoupdate.default.${alias}"
    fi
    [[ -r "$file" ]] || return 0

    local line tok deny="" allow=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"            # strip inline + whole-line comments
        # shellcheck disable=SC2086   # intentional word-split to grab first token
        set -- $line
        [[ $# -ge 1 ]] || continue
        tok="$1"
        if [[ "${tok:0:1}" == "+" ]]; then
            [[ -n "${tok:1}" ]] && allow+=" ${tok:1}"
        else
            deny+=" $tok"
        fi
    done < "$file"

    export MESH_AUTOUPDATE_DENY="${deny# }"
    export MESH_AUTOUPDATE_ALLOW="${allow# }"
}
