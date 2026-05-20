#!/usr/bin/env bash
# scripts/lib/managed-block.sh — splice block between mesh-managed markers.
# Source-only. Markers are case-insensitive (L16 / bug-2026-04-23 regression guard).
#
# Functions:
#   managed_block_apply <target> <slot>            (writes via stdin)
#   managed_block_in_sync <src-abs> <dst> <slot>   (drift detection, 0/1 rc)
#
# managed_block_apply: reads block content from stdin. Replaces any existing
# block in target matching the slot name (case-insensitive), or appends new
# one if absent. Old "dotfiles-managed:" markers are migrated to "mesh-managed:"
# in place.
#
# managed_block_in_sync: side-effect-free check for whether dst contains the
# block install.sh would produce. Used by doctor for drift detection (C12/D49).

managed_block_apply() {
    local target="$1" slot="$2"
    local content
    content=$(cat)
    local begin="# >>> BEGIN mesh-managed: $slot >>>"
    local end="# <<< END mesh-managed: $slot <<<"
    local block
    block="$begin
$content
$end"

    if [[ ! -f "$target" ]]; then
        printf '%s\n' "$block" > "$target"
        return 0
    fi

    # Use python3 for portable case-insensitive regex replace.
    python3 - "$target" "$slot" "$block" <<'PY'
import re, sys, pathlib
target, slot, new_block = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = target.read_text()
# CP4 A1-F-002: pre-detect orphan/mismatched markers for this slot. If
# BEGIN count != END count, the file's managed region is corrupted —
# replacing would either silently double-append (broken before) or skip
# the orphan marker entirely. Fail fast with rc=2 so caller can surface
# the corruption rather than masking it under a fresh block.
begin_pat = re.compile(
    r'^# >>> BEGIN (?:dotfiles|mesh)-managed: ' + re.escape(slot) + r' >>>',
    re.IGNORECASE | re.MULTILINE,
)
end_pat = re.compile(
    r'^# <<< END (?:dotfiles|mesh)-managed: ' + re.escape(slot) + r' <<<',
    re.IGNORECASE | re.MULTILINE,
)
b_count = len(begin_pat.findall(text))
e_count = len(end_pat.findall(text))
if b_count != e_count:
    print(
        f"managed-block: {target}: malformed markers for slot {slot!r} "
        f"(BEGIN={b_count}, END={e_count}); refusing to write",
        file=sys.stderr,
    )
    sys.exit(2)
# Match either dotfiles-managed: or mesh-managed: (case-insensitive), same slot.
pattern = re.compile(
    r'^# >>> BEGIN (?:dotfiles|mesh)-managed: ' + re.escape(slot) + r' >>>.*?^# <<< END (?:dotfiles|mesh)-managed: ' + re.escape(slot) + r' <<<$',
    re.IGNORECASE | re.MULTILINE | re.DOTALL
)
if pattern.search(text):
    new_text = pattern.sub(lambda m: new_block, text)
else:
    # Ensure existing content ends with exactly one newline before appending
    new_text = text.rstrip('\n') + '\n' + new_block + '\n' if text.strip() else new_block + '\n'
target.write_text(new_text)
PY
}

# Function: managed_block_in_sync <src-abs> <dst> <src-name>
#   Idempotency check used by doctor for drift detection. Returns 0 if the
#   content between the markers in dst matches src, regardless of:
#     - marker style (legacy `dotfiles-managed:` or canonical `mesh-managed:`)
#     - block position in the file (header lines before, trailing after)
#
# CP4 D-F-002: previous implementation reconstructed "preserved + begin + src
# + end" effectively anchoring drift detection at EOF — conflicting with the
# writer's in-place pattern.sub() that preserves position. Unified contract:
# the slot's payload IS the source of truth; markers and position are not.
# Markers must be present (else block never deployed) and marker counts must
# be balanced (else the file is corrupted and the writer would refuse).
managed_block_in_sync() {
    local src_abs="$1" dst="$2" src_name="$3"
    [[ -f "$src_abs" && -f "$dst" ]] || return 1

    local begin end
    if grep -qF -- "# >>> BEGIN mesh-managed: ${src_name} >>>" "$dst" 2>/dev/null \
       && grep -qF -- "# <<< END mesh-managed: ${src_name} <<<" "$dst" 2>/dev/null; then
        begin="# >>> BEGIN mesh-managed: ${src_name} >>>"
        end="# <<< END mesh-managed: ${src_name} <<<"
    elif grep -qF -- "# >>> BEGIN dotfiles-managed: ${src_name} >>>" "$dst" 2>/dev/null \
         && grep -qF -- "# <<< END dotfiles-managed: ${src_name} <<<" "$dst" 2>/dev/null; then
        begin="# >>> BEGIN dotfiles-managed: ${src_name} >>>"
        end="# <<< END dotfiles-managed: ${src_name} <<<"
    else
        return 1
    fi

    # Extract content strictly between the first marker pair.
    local extracted src_content
    extracted=$(awk -v b="$begin" -v e="$end" '
        $0 == b { in_block=1; next }
        $0 == e { if (in_block) { in_block=0; found=1; exit } }
        in_block { print }
        END { exit !found }
    ' "$dst" 2>/dev/null) || return 1

    # Read src verbatim. Strip a single trailing newline from both sides so
    # files that end without a newline still compare equal to ones that do
    # (mirrors print_with_eol semantics the writer's block uses).
    src_content=$(cat "$src_abs" 2>/dev/null) || return 1
    [[ "$extracted" == "$src_content" ]]
}
