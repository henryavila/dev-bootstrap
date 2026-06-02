#!/usr/bin/env bash
# secrets-manifest.sh — bash 3.2 reader for the secrets manifest (secrets layer).
#
# Stdin:  secrets manifest YAML (see docs/2026-06-02-secrets-layer-spec.md §4).
#         FLAT grammar (no deep nesting) so a line-based bash 3.2 parser is enough:
#           indent 0 : `version:` | `integrations:`
#           indent 2 : `<id>:`                       (integration key)
#           indent 4 : `<field>: <value>`            (scalar field of the integration)
#         Lists are inline only: `machines: [mac, ultron]`.
# Stdout: shell-evaluable assignments + `__SECRETS_MANIFEST_OK=1` sentinel on success.
# Stderr: "line N: msg" on rejection.
# Exit:   0 success, 1 syntax error.
#
# CONSUMER CONTRACT (mirrors yaml-parse.sh §10):
#   parsed=$(bash secrets-manifest.sh < manifest.yaml) || die "parser failed: $?"
#   eval "$parsed"
#   [ "${__SECRETS_MANIFEST_OK:-0}" = "1" ] || die "parse incomplete (no sentinel)"
#   NEVER `eval "$(bash secrets-manifest.sh ...)"` — command substitution discards
#   the parser's exit code under set -e, so partial output eval's as success.
#
# OUTPUT SHAPE:
#   MANIFEST_VERSION=<n>
#   INTEGRATION_COUNT=<N>
#   INTEGRATION_<i>_ID=<id>
#   INTEGRATION_<i>_<FIELD>=<value>            (FIELD upper-cased, '-'→'_')
#   INTEGRATION_<i>_MACHINES_COUNT=<n> + INTEGRATION_<i>_MACHINES_<n>=<host>
#   __SECRETS_MANIFEST_OK=1
#
# Recognized fields (validated by schema/secrets-manifest.schema.json, not here —
# this reader is permissive on field names so the schema owns the contract):
#   tier type source dest_resolver dest_path dest_file perms machines key
#   check login description
#
# Bash 3.2 floor (macOS /bin/bash). Run via `bash <path>`, not executed (+x); L13.

set -u

_die() { printf 'secrets-manifest: line %s: %s\n' "$1" "$2" >&2; exit 1; }

# Upper-case a key and map '-' → '_' (bash 3.2: no ${v^^}).
_key_norm() { printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'; }

# Strip a trailing inline comment and surrounding whitespace/quotes from a value.
_val_clean() {
    local v="$1"
    # drop surrounding double or single quotes if the whole value is quoted
    case "$v" in
        \"*\") v="${v#\"}"; v="${v%\"}" ;;
        \'*\') v="${v#\'}"; v="${v%\'}" ;;
    esac
    printf '%s' "$v"
}

linenum=0
version=""
int_idx=-1
out=""

emit() { out="$out$1
"; }

while IFS= read -r line || [ -n "$line" ]; do
    linenum=$((linenum + 1))

    # Tabs are forbidden (ambiguous indent).
    case "$line" in
        *"$(printf '\t')"*) _die "$linenum" "tabs are not allowed (use 2-space indent)" ;;
    esac

    # Blank lines and full-line comments are ignored (classified via `stripped`).
    stripped="${line#"${line%%[![:space:]]*}"}"   # content without leading ws
    [ -z "$stripped" ] && continue                # blank
    case "$stripped" in '#'*) continue ;; esac    # comment line

    # Compute indent = leading spaces count.
    indent_str="${line%%[![:space:]]*}"
    indent=${#indent_str}
    case "$indent_str" in *[!' ']*) _die "$linenum" "non-space indentation" ;; esac

    case "$indent" in
        0)
            case "$stripped" in
                version:*)
                    version="$(_val_clean "$(printf '%s' "${stripped#version:}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')")"
                    ;;
                integrations:) : ;;
                *) _die "$linenum" "unexpected top-level key: $stripped" ;;
            esac
            ;;
        2)
            # integration id: "<id>:"
            case "$stripped" in
                *:) ;;
                *) _die "$linenum" "expected '<id>:' at indent 2, got: $stripped" ;;
            esac
            id="${stripped%:}"
            case "$id" in
                ''|*[!a-zA-Z0-9_-]*) _die "$linenum" "invalid integration id: '$id'" ;;
            esac
            int_idx=$((int_idx + 1))
            emit "INTEGRATION_${int_idx}_ID='$id'"
            ;;
        4)
            [ "$int_idx" -ge 0 ] || _die "$linenum" "field at indent 4 before any integration"
            case "$stripped" in
                *:*) ;;
                *) _die "$linenum" "expected '<field>: <value>' at indent 4, got: $stripped" ;;
            esac
            key="${stripped%%:*}"
            val="${stripped#*:}"
            val="$(printf '%s' "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            keyn="$(_key_norm "$key")"
            case "$val" in
                \[*\])
                    # inline list: [a, b, c]
                    inner="${val#\[}"; inner="${inner%\]}"
                    n=0
                    OLDIFS="$IFS"; IFS=','
                    for elem in $inner; do
                        elem="$(printf '%s' "$elem" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
                        [ -z "$elem" ] && continue
                        elem="$(_val_clean "$elem")"
                        emit "INTEGRATION_${int_idx}_${keyn}_${n}='$(printf '%s' "$elem" | sed "s/'/'\\\\''/g")'"
                        n=$((n + 1))
                    done
                    IFS="$OLDIFS"
                    emit "INTEGRATION_${int_idx}_${keyn}_COUNT=$n"
                    ;;
                *)
                    val="$(_val_clean "$val")"
                    emit "INTEGRATION_${int_idx}_${keyn}='$(printf '%s' "$val" | sed "s/'/'\\\\''/g")'"
                    ;;
            esac
            ;;
        *)
            _die "$linenum" "unexpected indentation ($indent); flat grammar allows 0/2/4"
            ;;
    esac
done

printf 'MANIFEST_VERSION=%s\n' "${version:-0}"
printf 'INTEGRATION_COUNT=%s\n' "$((int_idx + 1))"
printf '%s' "$out"
printf '__SECRETS_MANIFEST_OK=1\n'
