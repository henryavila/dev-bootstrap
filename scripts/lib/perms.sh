#!/usr/bin/env bash
# scripts/lib/perms.sh — apply chmod to deployed files.
# Source-only. Mode is supplied by the caller (from a deploy.map entry's perms).

apply_perms() {
    local file="$1" mode="${2:-0644}"
    [[ -f "$file" ]] || return 0
    chmod "$mode" "$file"
}
