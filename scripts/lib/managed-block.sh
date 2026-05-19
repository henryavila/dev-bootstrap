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
#   Mirrors install.sh:deploy_managed_block's "is the on-disk block what
#   install.sh would produce?" idempotency check, without the side effects.
#   Returns 0 if dst is in sync under the managed_block protocol, 1
#   otherwise (markers missing, awk read failure, or block content diffs).
#
# Marker scope: matches the legacy `dotfiles-managed:` markers only,
# preserving doctor.sh's pre-migration semantics. The dual-marker
# (dotfiles|mesh, case-insensitive) handling that managed_block_apply
# uses is a separate concern — drift detection should be extended once
# install.sh fully migrates to mesh-managed.
managed_block_in_sync() {
    local src_abs="$1" dst="$2" src_name="$3"
    local begin="# >>> BEGIN dotfiles-managed: ${src_name} >>>"
    local end="# <<< END dotfiles-managed: ${src_name} <<<"

    # Markers absent means the block was never deployed (or was tampered
    # with destructively); install.sh would write it on the next run, so
    # reporting drift is the right thing.
    if ! grep -qF -- "$begin" "$dst" 2>/dev/null \
       || ! grep -qF -- "$end" "$dst" 2>/dev/null; then
        return 1
    fi

    # Reconstruct what install.sh would produce: lines outside markers
    # (preserved) + begin + src content (with trailing \n if missing) +
    # end. Compare byte-for-byte against current dst.
    local preserved
    if ! preserved=$(awk -v b="$begin" -v e="$end" '
        $0 == b { skip=1; next }
        $0 == e { skip=0; next }
        !skip { print }
    ' "$dst" 2>/dev/null); then
        return 1
    fi

    local tmp
    tmp=$(mktemp 2>/dev/null) || return 1
    {
        if [[ -n "$preserved" ]]; then
            printf '%s\n' "$preserved"
        fi
        printf '%s\n' "$begin"
        cat "$src_abs"
        # Mirror install.sh:print_with_eol — append \n iff src is non-empty
        # AND its last byte is non-newline. Required for cmp to match.
        if [[ -s "$src_abs" ]] && [[ -n "$(tail -c1 "$src_abs")" ]]; then
            printf '\n'
        fi
        printf '%s\n' "$end"
    } > "$tmp" 2>/dev/null

    if cmp -s "$tmp" "$dst"; then
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    return 1
}
