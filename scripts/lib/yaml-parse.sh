#!/usr/bin/env bash
# yaml-parse.sh — bash 3.2 subset YAML parser for items.yaml.
#
# Stdin:  YAML subset (see spec.md §C17).
# Stdout: shell-evaluable ITEM_<i>_<KEY>="value" + ITEM_COUNT=N.
#         Final line on success: __YAML_PARSE_OK=1 (sentinel).
# Stderr: parse errors with "line N column N: msg" on rejection.
# Exit:   0 success, 1 syntax error.
#
# CONSUMER CONTRACT (per spec §C17 post-checkpoint-2):
#   parsed=$(yaml-parse.sh < items.yaml) || die "parser failed: exit $?"
#   eval "$parsed"
#   [ "${__YAML_PARSE_OK:-0}" = "1" ] || die "parse incomplete (no sentinel)"
#
#   NEVER use `eval "$(yaml-parse.sh ...)"` directly — command substitution
#   discards parser exit codes under `set -e`, so partial output silently
#   eval's as if successful. The sentinel is the only safe way to verify
#   the parser ran to completion.
#
# Supported subset:
#   - Top-level sequence of maps. Item starts with "- name:" at indent 0.
#   - 10 fields: name, type, spec, script, check, post, desc, requires, platforms.
#   - Scalars: unquoted | "double" | 'single'.
#   - Lists: inline [a, b, c] or block (4-space indent, "- value").
#   - Comments: '# ...' alone on a line, or ' # ...' after value.
#   - Indent: 2 spaces, fixed. Tabs rejected.
#
# Rejected: anchors (&), aliases (*), tags (!), multi-line (|/>),
#           nested maps, multi-doc (---).

set -u

# --- Field classification ---
is_scalar_only()  { case "$1" in name|type|spec|script|check|desc) return 0;; esac; return 1; }
is_scalar_or_list() { case "$1" in post) return 0;; esac; return 1; }
is_list_only()    { case "$1" in requires|platforms) return 0;; esac; return 1; }

# --- Globals (parser state) ---
linenum=0
item_idx=-1
in_list_for=""        # current key collecting block list, "" otherwise
list_count=0

err() {
    printf 'yaml-parse error: line %s column %s: %s\n' "$1" "$2" "$3" >&2
    exit 1
}

# Uppercase + dash→underscore (bash 3.2: no ${var^^})
norm_key() { printf '%s' "$1" | tr 'a-z-' 'A-Z_'; }

# Escape value for embedding in `"..."` shell literal.
shell_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//\$/\\\$}"
    s="${s//\`/\\\`}"
    printf '%s' "$s"
}

# Trim leading whitespace.
ltrim() { local s="$1"; printf '%s' "${s#"${s%%[![:space:]]*}"}"; }
# Trim trailing whitespace.
rtrim() { local s="$1"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# Parse a scalar value (string already left-trimmed).
# Sets PARSED_VAL on success; returns 1 if value is empty.
parse_scalar() {
    local raw="$1" line="$2" col="$3"
    PARSED_VAL=""
    [ -z "$raw" ] && return 1
    local first="${raw:0:1}"
    if [ "$first" = '"' ]; then
        local i=1 len=${#raw} ch nxt out=""
        while [ $i -lt $len ]; do
            ch="${raw:$i:1}"
            # H1 fix: backslash in single-quotes is literal `\` (1 char).
            # Previously compared to `\\` (2 chars) → branch was unreachable.
            if [ "$ch" = '\' ] && [ $((i+1)) -lt $len ]; then
                nxt="${raw:$((i+1)):1}"
                case "$nxt" in
                    '"') out="$out\""; i=$((i+2)); continue;;
                    '\') out="$out\\"; i=$((i+2)); continue;;
                    n) out="$out
"; i=$((i+2)); continue;;
                    t) out=$(printf '%s\t' "$out"); i=$((i+2)); continue;;
                    *) out="$out$ch$nxt"; i=$((i+2)); continue;;
                esac
            elif [ "$ch" = '"' ]; then
                local rest; rest=$(ltrim "${raw:$((i+1))}")
                if [ -n "$rest" ] && [ "${rest:0:1}" != "#" ]; then
                    err "$line" $((col+i+1)) "unexpected content after closing quote"
                fi
                PARSED_VAL="$out"
                return 0
            fi
            out="$out$ch"
            i=$((i+1))
        done
        err "$line" "$col" "unterminated double-quoted string"
    elif [ "$first" = "'" ]; then
        local close="${raw#\'}"
        case "$close" in *\'*) ;; *) err "$line" "$col" "unterminated single-quoted string";; esac
        PARSED_VAL="${close%%\'*}"
        local rest; rest=$(ltrim "${close#*\'}")
        if [ -n "$rest" ] && [ "${rest:0:1}" != "#" ]; then
            err "$line" "$col" "unexpected content after closing quote"
        fi
        return 0
    else
        # H2 fix: `[` at start of scalar value means inline-list literal — invalid
        # for scalar-only keys. Caller distinguishes scalar vs list context, so
        # if parse_scalar sees `[`, scalar was expected.
        case "$raw" in
            \&*) err "$line" "$col" "anchor (&) not supported in this subset";;
            \**) err "$line" "$col" "alias (*) not supported in this subset";;
            \!*) err "$line" "$col" "tag (!) not supported in this subset";;
            \|*|\>*) err "$line" "$col" "multi-line scalar (|/>) not supported";;
            \[*) err "$line" "$col" "inline list value not allowed for scalar key";;
        esac
        local val="$raw"
        case "$val" in *' #'*) val="${val%% #*}";; esac
        PARSED_VAL=$(rtrim "$val")
        return 0
    fi
}

# Parse inline list "[a, b, 'c']". Sets INLINE_COUNT + INLINE_VAL_N.
parse_inline_list() {
    local raw="$1" line="$2" col="$3"
    case "$raw" in *\]*) ;; *) err "$line" "$col" "unterminated inline list";; esac
    local body="${raw#\[}"; body="${body%%\]*}"
    # F6/silent-failure fix: trailing content after `]` must be empty or comment.
    local after_close="${raw#*\]}"
    after_close=$(ltrim "$after_close")
    if [ -n "$after_close" ] && [ "${after_close:0:1}" != "#" ]; then
        err "$line" "$col" "trailing content after inline list ']'"
    fi
    INLINE_COUNT=0
    # bash 3.2 compatible split: replace , with newline, iterate
    local rest="$body" item
    while [ -n "$rest" ]; do
        case "$rest" in
            *,*) item="${rest%%,*}"; rest="${rest#*,}";;
            *)   item="$rest"; rest="";;
        esac
        item=$(ltrim "$item"); item=$(rtrim "$item")
        [ -z "$item" ] && continue
        # C2 fix: reject anchor/alias/tag in inline list items.
        case "$item" in
            \&*) err "$line" "$col" "anchor (&) not supported in inline list";;
            \**) err "$line" "$col" "alias (*) not supported in inline list";;
            \!*) err "$line" "$col" "tag (!) not supported in inline list";;
        esac
        # CX-M3 fix (checkpoint-3): the naive `,` split corrupts inline lists
        # whose values contain a comma inside quotes, e.g.
        # `post: ["echo alpha,beta"]` would split into [`"echo alpha`, `beta"`].
        # Quote-aware tokenization is out of scope for this subset; reject
        # the construct explicitly with a clear error. Real implementation
        # in Phase 3 should re-evaluate (proper state-machine parser).
        if [ "${item:0:1}" = '"' ] && [ "${item: -1}" != '"' ]; then
            err "$line" "$col" "inline list item starts with double-quote but doesn't end with one — comma inside quoted values not supported"
        fi
        if [ "${item:0:1}" = "'" ] && [ "${item: -1}" != "'" ]; then
            err "$line" "$col" "inline list item starts with single-quote but doesn't end with one — comma inside quoted values not supported"
        fi
        if [ "${item:0:1}" = '"' ] && [ "${item: -1}" = '"' ]; then
            item="${item:1:${#item}-2}"
        elif [ "${item:0:1}" = "'" ] && [ "${item: -1}" = "'" ]; then
            item="${item:1:${#item}-2}"
        fi
        eval "INLINE_VAL_$INLINE_COUNT=\$item"
        INLINE_COUNT=$((INLINE_COUNT + 1))
    done
}

# Emit the indexed list entries from INLINE_* into ITEM_<idx>_<KEY>_*.
emit_inline_list() {
    local key="$1" upkey i val
    upkey=$(norm_key "$key")
    printf 'ITEM_%d_%s_COUNT=%d\n' "$item_idx" "$upkey" "$INLINE_COUNT"
    i=0
    while [ $i -lt $INLINE_COUNT ]; do
        eval "val=\$INLINE_VAL_$i"
        printf 'ITEM_%d_%s_%d="%s"\n' "$item_idx" "$upkey" "$i" "$(shell_escape "$val")"
        i=$((i+1))
    done
}

# Close any pending block-list collection (called on blank line, new key, new item).
emit_pending_list() {
    if [ -n "$in_list_for" ]; then
        printf 'ITEM_%d_%s_COUNT=%d\n' "$item_idx" "$(norm_key "$in_list_for")" "$list_count"
        in_list_for=""
        list_count=0
    fi
}

# Process a key/value pair within the current item.
# Args: key, value-string (left-trimmed), col-of-value, line.
process_kv() {
    local key="$1" val="$2" col="$3" line="$4" upkey
    upkey=$(norm_key "$key")

    if is_list_only "$key"; then
        if [ -z "$val" ]; then
            in_list_for="$key"; list_count=0
            return 0
        fi
        if [ "${val:0:1}" = "[" ]; then
            parse_inline_list "$val" "$line" "$col"
            emit_inline_list "$key"
            return 0
        fi
        err "$line" "$col" "key '$key' requires a list value"
    fi

    if is_scalar_or_list "$key"; then
        if [ -z "$val" ]; then
            in_list_for="$key"; list_count=0
            return 0
        fi
        if [ "${val:0:1}" = "[" ]; then
            parse_inline_list "$val" "$line" "$col"
            emit_inline_list "$key"
            return 0
        fi
        # scalar form → normalize to count=1 list
        parse_scalar "$val" "$line" "$col" || PARSED_VAL=""
        printf 'ITEM_%d_%s_COUNT=1\n' "$item_idx" "$upkey"
        printf 'ITEM_%d_%s_0="%s"\n' "$item_idx" "$upkey" "$(shell_escape "$PARSED_VAL")"
        return 0
    fi

    if is_scalar_only "$key"; then
        parse_scalar "$val" "$line" "$col" || err "$line" "$col" "key '$key' requires a value"
        printf 'ITEM_%d_%s="%s"\n' "$item_idx" "$upkey" "$(shell_escape "$PARSED_VAL")"
        return 0
    fi

    # Menu-only fields (required, uninstall_tier) are consumed by the JS
    # manifest-reader; skip silently here rather than erroring.
    return 0
}

# Main parsing loop.
while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    linenum=$((linenum + 1))
    line="${raw_line%$'\r'}"
    if [ "${line#---}" != "$line" ] && [ "${line#---}" = "" ]; then
        err "$linenum" 1 "multi-document streams not supported"
    fi
    # C3 fix: tab guard fires only on tabs in the LEADING WHITESPACE.
    # Tabs inside quoted values (e.g. `desc: "with\ttab"`) are legitimate.
    leading_ws="${line%%[![:space:]]*}"
    case "$leading_ws" in
        *$'\t'*)
            pos=0
            while [ $pos -lt ${#leading_ws} ]; do
                [ "${leading_ws:$pos:1}" = $'\t' ] && break
                pos=$((pos+1))
            done
            err "$linenum" $((pos+1)) "tab character in indent forbidden (use 2-space indent)"
            ;;
    esac
    stripped=$(ltrim "$line")
    if [ -z "$stripped" ] || [ "${stripped:0:1}" = "#" ]; then
        emit_pending_list
        continue
    fi
    indent=${#leading_ws}

    if [ "$indent" -eq 0 ] && [ "${stripped:0:2}" = "- " ]; then
        emit_pending_list
        after="${stripped#- }"
        case "$after" in *:*) ;; *) err "$linenum" 3 "expected 'key: value' after list marker";; esac
        key="${after%%:*}"
        val_raw="${after#*:}"
        val=$(ltrim "$val_raw")
        item_idx=$((item_idx + 1))
        process_kv "$key" "$val" $((3 + ${#after} - ${#val_raw} + (${#val_raw} - ${#val}) + 1)) "$linenum"
        continue
    fi

    [ "$item_idx" -lt 0 ] && err "$linenum" 1 "content outside of any list item"

    if [ "$indent" -eq 2 ]; then
        emit_pending_list
        rest="${line:2}"
        case "$rest" in *:*) ;; *) err "$linenum" 3 "expected 'key: value'";; esac
        key="${rest%%:*}"
        val_raw="${rest#*:}"
        val=$(ltrim "$val_raw")
        process_kv "$key" "$val" $((2 + ${#key} + 2 + 1)) "$linenum"
        continue
    fi

    if [ "$indent" -eq 4 ]; then
        rest="${line:4}"
        if [ "${rest:0:2}" = "- " ]; then
            [ -z "$in_list_for" ] && err "$linenum" 5 "block list item without preceding key"
            litem="${rest#- }"
            parse_scalar "$(ltrim "$litem")" "$linenum" 7
            printf 'ITEM_%d_%s_%d="%s"\n' "$item_idx" "$(norm_key "$in_list_for")" "$list_count" "$(shell_escape "$PARSED_VAL")"
            list_count=$((list_count + 1))
            continue
        fi
        err "$linenum" 5 "nested map not supported in this subset"
    fi

    err "$linenum" $((indent+1)) "unexpected indent depth $indent"
done

emit_pending_list
printf 'ITEM_COUNT=%d\n' $((item_idx + 1))
# C-2 fix (checkpoint-2): emit success sentinel as the LAST line.
# Engines that consume via `eval "$(yaml-parse.sh ...)"` cannot detect parser
# errors otherwise — command-substitution discards the parser's exit code under
# `set -e`, so partial output gets eval'd as if successful. Consumers must
# assert __YAML_PARSE_OK=1 after eval to reject partial parses.
printf '__YAML_PARSE_OK=1\n'
