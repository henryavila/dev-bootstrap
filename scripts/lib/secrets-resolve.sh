#!/usr/bin/env bash
# shellcheck shell=bash
# secrets-resolve.sh — resolve a Tier-2 file integration's destination path.
#
# A `type: file` integration in the secrets manifest declares its destination
# either as an absolute `dest_path` (with ~ / $HOME expansion) OR as a
# `dest_resolver` (a named base-dir resolver) + `dest_file` (basename).
#
# Named resolvers exist because some tools put their config at a location that
# varies per machine (composer: ~/.composer legacy vs ~/.config/composer XDG).
# The authoritative answer is asked of the tool itself when possible.
#
# Public API (sourced, not executed):
#   secrets_resolve_home <resolver>   echo the base dir for a named resolver;
#                                     rc 0 ok, rc 2 unknown resolver.
#   secrets_resolver_list             echo every known resolver, one per line.
#   secrets_dest_path <path> <resolver> <file>
#                                     echo the absolute destination. Exactly one
#                                     of <path> / (<resolver>+<file>) must be set.
#                                     rc 0 ok, rc 2 on bad/missing inputs.
#
# Bash 3.2 floor (macOS /bin/bash). No eval / command-substitution-into-eval (L04).

[ -n "${_SECRETS_RESOLVE_LOADED:-}" ] && return 0
_SECRETS_RESOLVE_LOADED=1

# Echo the base directory for a named resolver.
secrets_resolve_home() {
    local resolver="$1"
    case "$resolver" in
        composer-home)
            # Authoritative: ask composer. Falls back when composer is absent
            # (e.g. deploying before the languages bundle installs it).
            if command -v composer >/dev/null 2>&1; then
                local h
                h="$(composer config --global home 2>/dev/null)"
                if [ -n "$h" ]; then printf '%s' "$h"; return 0; fi
            fi
            if [ -n "${COMPOSER_HOME:-}" ]; then printf '%s' "$COMPOSER_HOME"; return 0; fi
            if [ -d "$HOME/.composer" ]; then printf '%s' "$HOME/.composer"; return 0; fi
            printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/composer"
            return 0
            ;;
        npm-home)
            # npm reads ~/.npmrc by default; honor $NPM_CONFIG_USERCONFIG dir.
            if [ -n "${NPM_CONFIG_USERCONFIG:-}" ]; then
                printf '%s' "$(dirname "$NPM_CONFIG_USERCONFIG")"; return 0
            fi
            printf '%s' "$HOME"
            return 0
            ;;
        xdg-config)
            printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}"
            return 0
            ;;
        home)
            printf '%s' "$HOME"
            return 0
            ;;
        *)
            return 2
            ;;
    esac
}

secrets_resolver_list() {
    printf '%s\n' composer-home npm-home xdg-config home
}

# Expand a leading ~ and a literal $HOME in an absolute-ish path.
_secrets_expand_path() {
    local p="$1"
    case "$p" in
        '~') p="$HOME" ;;
        # shellcheck disable=SC2088  # case pattern matches a literal leading ~
        '~/'*) p="$HOME/${p#\~/}" ;;
    esac
    # literal $HOME (and ${HOME}) → $HOME (parameter substitution, not eval).
    p="${p/\$\{HOME\}/$HOME}"
    p="${p/\$HOME/$HOME}"
    printf '%s' "$p"
}

# secrets_dest_path <dest_path> <dest_resolver> <dest_file>
secrets_dest_path() {
    local dp="$1" dr="$2" df="$3"
    if [ -n "$dp" ]; then
        if [ -n "$dr" ] || [ -n "$df" ]; then
            echo "secrets_dest_path: set dest_path OR dest_resolver+dest_file, not both" >&2
            return 2
        fi
        _secrets_expand_path "$dp"
        return 0
    fi
    if [ -z "$dr" ] || [ -z "$df" ]; then
        echo "secrets_dest_path: need dest_path, or both dest_resolver and dest_file" >&2
        return 2
    fi
    local base
    base="$(secrets_resolve_home "$dr")" || {
        echo "secrets_dest_path: unknown dest_resolver '$dr'" >&2
        return 2
    }
    printf '%s/%s' "$base" "$df"
}
