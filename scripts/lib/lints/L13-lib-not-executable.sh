#!/usr/bin/env bash
# L13 — files under scripts/lib/ are source-only and must not carry the
# executable bit. Runtime entrypoints live in bin/, scripts/runners/, and
# scripts/internal/ (per Phase 2 4-way split, spec §C18).
#
# Exceptions (allowlist):
#   - yaml-parse.sh  dual-mode standalone parser. Its docstring + the
#                    parser test invoke it directly (`"$PARSER" < input`),
#                    so it legitimately needs +x.
#
# Spec: §C21. Phase 5 Task 5.2.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

# yaml-parse.sh is the dual-mode exception (invoked as "$PARSER").
_l13_allow() { grep -vE '(^|/)yaml-parse\.sh$' || true; }

# drvfs (/mnt/<drive>) reports every file as executable. Probe MUST live
# under scripts/lib so we sample the same filesystem the lint scans.
_l13_fs_honors_mode() {
    local probe="$ROOT/scripts/lib/.l13-mode-probe.$$"
    : > "$probe" || return 1
    chmod -x "$probe" 2>/dev/null || true
    if [[ -x "$probe" ]]; then
        rm -f "$probe"
        return 1
    fi
    rm -f "$probe"
    return 0
}

if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Tracked: git index modes (drvfs-safe).
    hits=$(git -C "$ROOT" ls-files -s -- scripts/lib \
        | awk '$1 == "100755" { print $4 }' \
        | grep '\.sh$' \
        | _l13_allow)
    # Untracked +x files (the unit-test injection) only when chmod works.
    if _l13_fs_honors_mode; then
        untracked=""
        while IFS= read -r rel; do
            [[ -z "$rel" ]] && continue
            [[ "$rel" == *.sh ]] || continue
            [[ -x "$ROOT/$rel" ]] || continue
            untracked+="$rel"$'\n'
        done < <(git -C "$ROOT" ls-files --others --exclude-standard -- scripts/lib)
        hits=$(printf '%s\n%s' "$hits" "$untracked" | _l13_allow | sed '/^$/d' | sort -u)
    fi
else
    hits=$(find "$ROOT/scripts/lib" -type f -name '*.sh' -perm -u+x 2>/dev/null \
        | _l13_allow)
fi

if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | sed "s|^$ROOT/||; s|^|L13: |; s|$| (source-only; chmod -x)|"
    exit 1
fi
exit 0
