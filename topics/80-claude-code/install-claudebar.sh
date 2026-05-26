#!/usr/bin/env bash
# Custom installer for claudebar (Claude Code statusline).
# Engine sources this file inside a subshell and calls check(), install(),
# verify(), rollback() via the custom driver contract.
#
# install() clones the repo then delegates to claudebar's own install.sh
# (--non-interactive) so this script never reimplements install rules.

readonly CLAUDEBAR_REPO="https://github.com/henryavila/claudebar.git"
readonly CLAUDEBAR_DIR="$HOME/.claude/statusline"
readonly CLAUDEBAR_SCRIPT="$CLAUDEBAR_DIR/statusline.sh"
readonly CLAUDE_SETTINGS="$HOME/.claude/settings.json"

check() {
    [[ -x "$CLAUDEBAR_SCRIPT" ]] || return 1
    [[ -f "$CLAUDE_SETTINGS" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local cmd
    cmd="$(jq -r '.statusLine.command // empty' "$CLAUDE_SETTINGS" 2>/dev/null)"
    [[ "$cmd" == *statusline/statusline.sh ]]
}

install() {
    if [[ ! -d "$CLAUDEBAR_DIR/.git" ]]; then
        git clone --depth 1 "$CLAUDEBAR_REPO" "$CLAUDEBAR_DIR"
    fi
    "$BASH" "$CLAUDEBAR_DIR/install.sh" --non-interactive
}

verify() {
    check
}

rollback() {
    if [[ -f "$CLAUDE_SETTINGS" ]] && command -v jq >/dev/null 2>&1; then
        local tmp
        tmp=$(mktemp)
        if jq 'del(.statusLine)' "$CLAUDE_SETTINGS" > "$tmp" && jq empty "$tmp" 2>/dev/null; then
            mv "$tmp" "$CLAUDE_SETTINGS"
        else
            rm -f "$tmp"
        fi
    fi
    [[ -d "$CLAUDEBAR_DIR" ]] && rm -rf "$CLAUDEBAR_DIR"
}
