# shellcheck shell=bash
# scripts/lib/ia-discover.sh — multi-root disk discovery for `mesh ia`.
# Source-only (no top-level execution).
#
# herdr (the agent multiplexer) only knows already-OPEN workspaces; it has no
# notion of all the repos on disk across different roots. This lib fills that
# gap: it reads a per-machine list of roots, scans each ONE level deep, and
# emits the git repos found as `name<TAB>path` rows — the catalogue the picker
# and the focus-or-create handoff consume.
#
# Roots come from $IA_ROOTS (a `:`- or newline-separated list, personal → set in
# mesh-identity). When unset, a per-OS default is derived so a fork without
# IA_ROOTS still gets something sensible:
#   mac        → /Volumes/External/Code + $HOME
#   wsl|linux  → ${CODE_DIR:-$HOME/code} + $HOME
# Only existing roots are scanned; a missing root contributes nothing (never an
# error) so the same IA_ROOTS can be shared across machines.

# Per-OS default roots, one per line. CODE_DIR (if exported via config.env) wins
# over the ~/code fallback on WSL/Linux.
ia_default_roots() {
    case "$(uname -s)" in
        Darwin)
            printf '%s\n%s\n' "/Volumes/External/Code" "$HOME"
            ;;
        *)
            printf '%s\n%s\n' "${CODE_DIR:-$HOME/code}" "$HOME"
            ;;
    esac
}

# Resolved roots, one per line: $IA_ROOTS split on `:` and newlines, `~`
# expanded, blanks dropped. Falls back to ia_default_roots when IA_ROOTS unset.
ia_roots() {
    local raw r
    raw="${IA_ROOTS:-}"
    if [[ -z "$raw" ]]; then
        ia_default_roots
        return 0
    fi
    # `:`-separated OR newline-separated; normalise both to newlines. The
    # `|| [[ -n "$r" ]]` keeps the final element when the input has no trailing
    # newline (`read` returns non-zero on EOF yet still set $r).
    printf '%s' "$raw" | tr ':' '\n' | while IFS= read -r r || [[ -n "$r" ]]; do
        [[ -n "$r" ]] || continue
        r="${r/#\~/$HOME}"
        printf '%s\n' "$r"
    done
}

# Discover git repos one level under each root. Emits `name<TAB>abspath`, one per
# line, sorted + de-duped by line (so overlapping roots don't double-count, while
# two distinct repos that share a basename are both kept — the picker shows the
# path to disambiguate). A repo is any child dir containing `.git` (dir OR file,
# so submodules/worktrees count).
ia_discover() {
    {
        local root d
        while IFS= read -r root; do
            [[ -n "$root" && -d "$root" ]] || continue
            for d in "$root"/*/; do
                d="${d%/}"
                [[ -d "$d" ]] || continue           # literal glob when root is empty
                [[ -e "$d/.git" ]] || continue       # git repo (dir or gitfile)
                printf '%s\t%s\n' "${d##*/}" "$d"
            done
        done < <(ia_roots)
    } | LC_ALL=C sort -u
}

# Filter the catalogue by a case-insensitive substring on the NAME (any
# position). Emits matching `name<TAB>path` rows. Empty term → everything.
ia_match() {
    local term="${1:-}"
    if [[ -z "$term" ]]; then
        ia_discover
        return 0
    fi
    local lc name path
    lc="$(printf '%s' "$term" | tr '[:upper:]' '[:lower:]')"
    while IFS=$'\t' read -r name path; do
        case "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" in
            *"$lc"*) printf '%s\t%s\n' "$name" "$path" ;;
        esac
    done < <(ia_discover)
}
