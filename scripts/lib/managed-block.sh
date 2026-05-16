#!/usr/bin/env bash
# scripts/lib/managed-block.sh — splice block between mesh-managed markers.
# Source-only. Markers are case-insensitive (L16 / bug-2026-04-23 regression guard).
#
# Function: managed_block_apply <target-file> <slot-name>
#   Reads block content from stdin. Replaces any existing block in target
#   matching the slot name (case-insensitive), or appends new one if absent.
#   Old "dotfiles-managed:" markers are migrated to "mesh-managed:" in place.

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
