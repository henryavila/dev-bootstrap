#!/usr/bin/env bash
# scripts/lib/topic-cleanup.sh — TOPIC-LEVEL drift cleanup for installed artifacts.
#
# Source this file from a topic's install.<suffix>.sh, then call
# uninstall_apply with the path to a manifest. The manifest lists
# artifacts the topic used to install but no longer does.
#
# Manifest format (one removal per line):
#   verb:arg
#
# Supported verbs:
#   apt:<package>            sudo apt-get purge   (Linux only; no-op on Mac)
#   brew:<formula>           brew uninstall       (Mac only;   no-op on Linux)
#   brew-cask:<cask>         brew uninstall --cask
#   font:<cask>              alias of brew-cask (semantic clarity for fonts)
#   clone:<dir-name>         rm -rf ~/.local/share/<dir-name>
#   zinit:<owner>/<repo>     rm -rf ~/.local/share/zinit/plugins/<owner>---<repo>
#   user-bin:<name>          rm -f ~/.local/bin/<name>
#   sys-bin:<name>           sudo rm -f /usr/local/bin/<name>

# shellcheck shell=bash

# Source shared handlers (single source of truth for all verb implementations).
_CLEANUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$_CLEANUP_DIR/uninstall-handlers.sh"

# ─── Public entry point ──────────────────────────────────────────────
uninstall_apply() {
    local manifest="$1"
    [[ -f "$manifest" ]] || return 0

    local line verb arg
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "${line// }" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" != *:* ]]; then
            warn "topic-cleanup: malformed line (no verb:arg) — '$line'"
            continue
        fi
        verb="${line%%:*}"
        arg="${line#*:}"

        verb="${verb#"${verb%%[![:space:]]*}"}"; verb="${verb%"${verb##*[![:space:]]}"}"
        arg="${arg#"${arg%%[![:space:]]*}"}";    arg="${arg%"${arg##*[![:space:]]}"}"

        if [[ -z "$verb" ]] || [[ -z "$arg" ]]; then
            warn "topic-cleanup: empty verb or arg — '$line'"
            continue
        fi

        case "$verb" in
            apt)        _uninstall_apt        "$arg" ;;
            brew)       _uninstall_brew       "$arg" ;;
            brew-cask)  _uninstall_brew_cask  "$arg" ;;
            font)       _uninstall_brew_cask  "$arg" ;;
            clone)      _uninstall_clone      "$arg" ;;
            zinit)      _uninstall_zinit      "$arg" ;;
            user-bin)   _uninstall_user_bin   "$arg" ;;
            sys-bin)    _uninstall_sys_bin    "$arg" ;;
            *)          warn "topic-cleanup: unknown verb '$verb' (line: '$line')" ;;
        esac
    done < "$manifest"
}
