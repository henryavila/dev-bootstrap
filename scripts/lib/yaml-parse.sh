#!/usr/bin/env bash
# yaml-parse.sh — bash 3.2 subset YAML parser for manifest.yaml v2.
#
# Stdin:  manifest.yaml v2 (hierarchical: topic + bundles[] + items[] + options[]).
#         See docs/2026-05-28-mesh-manifest-v2-spec.md §10 for the contract.
# Stdout: shell-evaluable TOPIC_* / BUNDLE_<b>_* / BUNDLE_<b>_ITEM_<i>_* /
#         BUNDLE_<b>_OPTION_<o>_* assignments + BUNDLE_COUNT=N.
#         Final line on success: __YAML_PARSE_OK=1 (sentinel).
# Stderr: parse errors with "line N column N: msg" on rejection.
# Exit:   0 success, 1 syntax error.
#
# CONSUMER CONTRACT (spec §10):
#   parsed=$(yaml-parse.sh < manifest.yaml) || die "parser failed: exit $?"
#   eval "$parsed"
#   [ "${__YAML_PARSE_OK:-0}" = "1" ] || die "parse incomplete (no sentinel)"
#
#   NEVER use `eval "$(yaml-parse.sh ...)"` directly — command substitution
#   discards parser exit codes under `set -e`, so partial output silently
#   eval's as if successful. The sentinel is the only safe completeness check.
#
# OUTPUT SHAPE (spec §10.1):
#   TOPIC_LABEL / TOPIC_HINT (strings), TOPIC_REQUIRED / TOPIC_ORDER (1/0, num).
#     topic.description is UI-only — skipped (not emitted).
#   BUNDLE_COUNT=N
#   BUNDLE_<b>_{NAME,LABEL,DESC,ICON_NAME,MEMBERSHIP} (str), _{REQUIRED,DEFAULT_SELECTED} (1/0),
#     _{PLATFORMS,REQUIRES_BUNDLES}_COUNT + _<n> (lists).
#   BUNDLE_<b>_ITEM_COUNT, BUNDLE_<b>_ITEM_<i>_{NAME,TYPE,SPEC,SCRIPT,CHECK,WHEN,
#     POST,ROLLBACK} (str), _IDEMPOTENT/_SOFT_FAIL/_AUTOUPDATE (1/0),
#     _UNINSTALL_TIER (num), _PLATFORMS_COUNT + _<n> (inline list only).
#   BUNDLE_<b>_OPTION_COUNT, BUNDLE_<b>_OPTION_<o>_{NAME,TYPE,LABEL,ENV,
#     DEFAULT_FROM,WHEN} (str), _{REQUIRED} (1/0), _{REQUIRED_MIN} (num),
#     _DEFAULT (str, or _DEFAULT_COUNT + _<n> for inline-list default).
#     option.{description,choices,derive_from,source} are UI-only — skipped.
#
# EMISSION POLICY (spec §10.1): emit only keys present in the YAML. Absent
#   optional fields are NOT emitted; both consumers (bash engine, TS reader)
#   apply schema defaults themselves (default_selected=true, required=false…).
#   Booleans normalize to 1/0. Numbers emitted bare. Keys upper-case, `-`→`_`.
#
# VALIDATOR META MODE (opt-in, MESH_YAML_META=1): additionally emits, per option,
#   _HAS_CHOICES=1 + _CHOICE_COUNT + _CHOICE_DEFAULT_COUNT (block-form choices),
#   _DERIVE_FROM="<opt>", _SOURCE="<path>". These feed validate-manifest.sh's
#   cross-reference rules (§8 rules 11/14/15/16). Default (engine) output stays
#   exactly per §10 — the choices/derive_from/source sub-trees are skipped.
#
# Supported subset / indent map (spec §10.2, 2-space indent, tabs forbidden):
#   0  topic:/bundles: keys           4  bundle scalar / items:/options: keys
#   2  topic scalar / '- name:' bundle 6  '- name:' item|option start, '- value'
#   8  item/option scalar               (choices subtree at 10 is skip-counted)
#
# Rejected (carried from v1): anchors (&), aliases (*), tags (!), multi-doc (---).
#   topic.description block scalar (|) is gracefully skipped, not rejected.

set -u

# --- Globals (parser state) ---
linenum=0
section=""            # "" | topic | bundles
bundle_idx=-1
item_idx=-1           # reset per bundle
option_idx=-1         # reset per bundle
list4=""              # "" | items | options | requires_bundles | platforms
cur6=""               # "" | item | option

# block scalar-list collection (requires_bundles / platforms at bundle level).
# Entries sit at indent 6; routing is by list4 (no separate indent tracking).
bl_active=0
bl_prefix=""
bl_count=0

# subtree skip (topic.description block; option.choices block)
skip_active=0
skip_indent=0
skip_kind=""          # "" | plain | choices
choices_base=""
choices_n=0
choices_def=0

META="${MESH_YAML_META:-0}"

err() {
    printf 'yaml-parse error: line %s column %s: %s\n' "$1" "$2" "$3" >&2
    exit 1
}

# Uppercase + dash→underscore (bash 3.2: no ${var^^}).
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

ltrim() { local s="$1"; printf '%s' "${s#"${s%%[![:space:]]*}"}"; }
rtrim() { local s="$1"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# Parse a scalar value (already left-trimmed). Sets PARSED_VAL; returns 1 if empty.
parse_scalar() {
    local raw="$1" line="$2" col="$3"
    PARSED_VAL=""
    [ -z "$raw" ] && return 1
    local first="${raw:0:1}"
    if [ "$first" = '"' ]; then
        local i=1 len=${#raw} ch nxt out=""
        while [ $i -lt $len ]; do
            ch="${raw:$i:1}"
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
        case "$raw" in
            \&*) err "$line" "$col" "anchor (&) not supported in this subset";;
            \**) err "$line" "$col" "alias (*) not supported in this subset";;
            \!*) err "$line" "$col" "tag (!) not supported in this subset";;
            \|*|\>*) err "$line" "$col" "multi-line scalar (|/>) not supported here";;
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
    local after_close="${raw#*\]}"
    after_close=$(ltrim "$after_close")
    if [ -n "$after_close" ] && [ "${after_close:0:1}" != "#" ]; then
        err "$line" "$col" "trailing content after inline list ']'"
    fi
    INLINE_COUNT=0
    local rest="$body" item
    while [ -n "$rest" ]; do
        case "$rest" in
            *,*) item="${rest%%,*}"; rest="${rest#*,}";;
            *)   item="$rest"; rest="";;
        esac
        item=$(ltrim "$item"); item=$(rtrim "$item")
        [ -z "$item" ] && continue
        case "$item" in
            \&*) err "$line" "$col" "anchor (&) not supported in inline list";;
            \**) err "$line" "$col" "alias (*) not supported in inline list";;
            \!*) err "$line" "$col" "tag (!) not supported in inline list";;
        esac
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

# Emit INLINE_* entries under a given variable prefix.
emit_inline_to() {
    local prefix="$1" i val
    printf '%s_COUNT=%d\n' "$prefix" "$INLINE_COUNT"
    i=0
    while [ $i -lt $INLINE_COUNT ]; do
        eval "val=\$INLINE_VAL_$i"
        printf '%s_%d="%s"\n' "$prefix" "$i" "$(shell_escape "$val")"
        i=$((i+1))
    done
}

# Emit a key/value as string | boolean(1/0) | bare-number.
# Args: VARNAME kind(str|bool|num) raw-value line col
emit_kv() {
    local var="$1" kind="$2" raw="$3" line="$4" col="$5"
    case "$kind" in
        bool)
            parse_scalar "$raw" "$line" "$col" || err "$line" "$col" "boolean key requires a value"
            case "$PARSED_VAL" in
                true|True|TRUE|yes|Yes|YES|on|On|1)  printf '%s=1\n' "$var";;
                false|False|FALSE|no|No|NO|off|Off|0) printf '%s=0\n' "$var";;
                *) err "$line" "$col" "expected boolean for ${var##*_}, got '$PARSED_VAL'";;
            esac
            ;;
        num)
            parse_scalar "$raw" "$line" "$col" || err "$line" "$col" "numeric key requires a value"
            case "$PARSED_VAL" in
                ''|*[!0-9]*) printf '%s="%s"\n' "$var" "$(shell_escape "$PARSED_VAL")";;
                *) printf '%s=%s\n' "$var" "$PARSED_VAL";;
            esac
            ;;
        *)
            parse_scalar "$raw" "$line" "$col" || err "$line" "$col" "key requires a value"
            printf '%s="%s"\n' "$var" "$(shell_escape "$PARSED_VAL")"
            ;;
    esac
}

close_block() {
    if [ "$bl_active" = 1 ]; then
        printf '%s_COUNT=%d\n' "$bl_prefix" "$bl_count"
        bl_active=0; bl_prefix=""; bl_count=0
    fi
}

# Emit ITEM_COUNT / OPTION_COUNT for the bundle that is closing.
close_bundle() {
    if [ "$bundle_idx" -ge 0 ]; then
        printf 'BUNDLE_%d_ITEM_COUNT=%d\n' "$bundle_idx" $((item_idx + 1))
        printf 'BUNDLE_%d_OPTION_COUNT=%d\n' "$bundle_idx" $((option_idx + 1))
    fi
}

# Handle a bundle-level key (the '- name:' start and indent-4 scalars/sections).
handle_bundle_key() {
    local key="$1" val="$2" line="$3" col="$4" up
    case "$key" in
        name|label|desc|icon_name|membership)
            list4=""; cur6=""
            emit_kv "BUNDLE_${bundle_idx}_$(norm_key "$key")" str "$val" "$line" "$col";;
        required)
            list4=""; cur6=""
            emit_kv "BUNDLE_${bundle_idx}_REQUIRED" bool "$val" "$line" "$col";;
        default_selected)
            list4=""; cur6=""
            emit_kv "BUNDLE_${bundle_idx}_DEFAULT_SELECTED" bool "$val" "$line" "$col";;
        platforms|requires_bundles)
            cur6=""
            up=$(norm_key "$key")
            if [ -z "$val" ]; then
                list4="$key"
                bl_active=1; bl_prefix="BUNDLE_${bundle_idx}_${up}"; bl_count=0
            elif [ "${val:0:1}" = "[" ]; then
                parse_inline_list "$val" "$line" "$col"
                emit_inline_to "BUNDLE_${bundle_idx}_${up}"
                list4="$key"
            else
                err "$line" "$col" "key '$key' requires a list value"
            fi;;
        items)
            [ -n "$val" ] && [ "${val:0:1}" != "#" ] && err "$line" "$col" "'items:' takes no inline value"
            list4="items"; cur6="";;
        options)
            [ -n "$val" ] && [ "${val:0:1}" != "#" ] && err "$line" "$col" "'options:' takes no inline value"
            list4="options"; cur6="";;
        *) err "$line" "$col" "unknown bundle key '$key'";;
    esac
}

# Handle an item key (the '- name:' start and indent-8 item scalars).
handle_item_key() {
    local key="$1" val="$2" line="$3" col="$4"
    local base="BUNDLE_${bundle_idx}_ITEM_${item_idx}"
    case "$key" in
        name|type|spec|script|check|when|post|rollback)
            emit_kv "${base}_$(norm_key "$key")" str "$val" "$line" "$col";;
        idempotent)
            emit_kv "${base}_IDEMPOTENT" bool "$val" "$line" "$col";;
        soft_fail)
            emit_kv "${base}_SOFT_FAIL" bool "$val" "$line" "$col";;
        autoupdate)
            emit_kv "${base}_AUTOUPDATE" bool "$val" "$line" "$col";;
        restart_service)
            emit_kv "${base}_RESTART_SERVICE" str "$val" "$line" "$col";;
        uninstall_tier)
            emit_kv "${base}_UNINSTALL_TIER" num "$val" "$line" "$col";;
        platforms)
            if [ "${val:0:1}" = "[" ]; then
                parse_inline_list "$val" "$line" "$col"
                emit_inline_to "${base}_PLATFORMS"
            else
                err "$line" "$col" "per-item 'platforms:' must be an inline list [..]"
            fi;;
        *) err "$line" "$col" "unknown item key '$key'";;
    esac
}

# Handle an option key (the '- name:' start and indent-8 option scalars).
handle_option_key() {
    local key="$1" val="$2" line="$3" col="$4"
    local base="BUNDLE_${bundle_idx}_OPTION_${option_idx}"
    case "$key" in
        name|type|label|env|default_from|when)
            emit_kv "${base}_$(norm_key "$key")" str "$val" "$line" "$col";;
        required)
            emit_kv "${base}_REQUIRED" bool "$val" "$line" "$col";;
        required_min)
            emit_kv "${base}_REQUIRED_MIN" num "$val" "$line" "$col";;
        default)
            if [ "${val:0:1}" = "[" ]; then
                parse_inline_list "$val" "$line" "$col"
                emit_inline_to "${base}_DEFAULT"
            else
                emit_kv "${base}_DEFAULT" str "$val" "$line" "$col"
            fi;;
        description)
            : ;;   # UI-only single-line scalar — skip (not emitted)
        choices)
            # UI-only subtree — skip. In META mode, count entries for §8 rule 14.
            skip_active=1; skip_indent=8; skip_kind="choices"
            choices_base="$base"; choices_n=0; choices_def=0;;
        derive_from)
            [ "$META" = 1 ] && emit_kv "${base}_DERIVE_FROM" str "$val" "$line" "$col";;
        source)
            [ "$META" = 1 ] && emit_kv "${base}_SOURCE" str "$val" "$line" "$col";;
        *) err "$line" "$col" "unknown option key '$key'";;
    esac
}

emit_choice_meta() {
    if [ "$skip_kind" = choices ] && [ "$META" = 1 ] && [ -n "$choices_base" ]; then
        printf '%s_HAS_CHOICES=1\n' "$choices_base"
        printf '%s_CHOICE_COUNT=%d\n' "$choices_base" "$choices_n"
        printf '%s_CHOICE_DEFAULT_COUNT=%d\n' "$choices_base" "$choices_def"
    fi
}

# --- Main parsing loop ---
while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    linenum=$((linenum + 1))
    line="${raw_line%$'\r'}"

    if [ "${line#---}" != "$line" ] && [ "${line#---}" = "" ]; then
        err "$linenum" 1 "multi-document streams not supported"
    fi

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
    indent=${#leading_ws}

    # Blank / comment line.
    if [ -z "$stripped" ] || [ "${stripped:0:1}" = "#" ]; then
        [ "$skip_active" = 1 ] && continue
        close_block
        continue
    fi

    # Subtree skip (topic.description block; option.choices block).
    if [ "$skip_active" = 1 ]; then
        if [ "$indent" -gt "$skip_indent" ]; then
            if [ "$skip_kind" = choices ]; then
                case "$stripped" in "- "*) choices_n=$((choices_n + 1));; esac
                case "$stripped" in
                    *"default: true"*|*"default:true"*|*"default: True"*) choices_def=$((choices_def + 1));;
                esac
            fi
            continue
        fi
        emit_choice_meta
        skip_active=0; skip_kind=""; choices_base=""
        # fall through to process this line at its own indent
    fi

    # ===== indent 0: topic: / bundles: =====
    if [ "$indent" -eq 0 ]; then
        close_block
        case "$stripped" in
            topic:*)
                rest="${stripped#topic:}"; rest=$(ltrim "$rest")
                { [ -n "$rest" ] && [ "${rest:0:1}" != "#" ]; } && err "$linenum" 7 "unexpected value after 'topic:'"
                close_bundle
                section="topic";;
            bundles:*)
                rest="${stripped#bundles:}"; rest=$(ltrim "$rest")
                { [ -n "$rest" ] && [ "${rest:0:1}" != "#" ]; } && err "$linenum" 10 "unexpected value after 'bundles:'"
                section="bundles";;
            *) err "$linenum" 1 "unexpected top-level key (expected 'topic:' or 'bundles:')";;
        esac
        continue
    fi

    [ -z "$section" ] && err "$linenum" 1 "content before 'topic:' or 'bundles:'"

    # ===== indent 2: topic scalar OR '- name:' bundle start =====
    if [ "$indent" -eq 2 ]; then
        close_block
        if [ "$section" = "topic" ]; then
            case "$stripped" in *:*) ;; *) err "$linenum" 3 "expected 'key: value'";; esac
            key="${stripped%%:*}"; valraw="${stripped#*:}"; val=$(ltrim "$valraw")
            col=$((2 + ${#key} + 2))
            case "$key" in
                label|hint) emit_kv "TOPIC_$(norm_key "$key")" str "$val" "$linenum" "$col";;
                required)   emit_kv "TOPIC_REQUIRED" bool "$val" "$linenum" "$col";;
                order)      emit_kv "TOPIC_ORDER" num "$val" "$linenum" "$col";;
                description) skip_active=1; skip_indent=2; skip_kind="plain";;
                *) err "$linenum" 3 "unknown topic key '$key'";;
            esac
            continue
        fi
        # section == bundles
        case "$stripped" in "- "*) ;; *) err "$linenum" 3 "expected bundle list item '- name: ...'";; esac
        close_bundle
        bundle_idx=$((bundle_idx + 1)); item_idx=-1; option_idx=-1; list4=""; cur6=""
        after="${stripped#- }"
        case "$after" in *:*) ;; *) err "$linenum" 5 "expected 'key: value' after '-'";; esac
        key="${after%%:*}"; valraw="${after#*:}"; val=$(ltrim "$valraw")
        handle_bundle_key "$key" "$val" "$linenum" 5
        continue
    fi

    # ===== indent 4: bundle scalar / items:/options: / list keys =====
    if [ "$indent" -eq 4 ]; then
        [ "$section" = "bundles" ] || err "$linenum" 5 "unexpected indent under 'topic:'"
        [ "$bundle_idx" -ge 0 ] || err "$linenum" 5 "bundle content before any '- name:'"
        close_block
        case "$stripped" in *:*) ;; *) err "$linenum" 5 "expected 'key: value'";; esac
        key="${stripped%%:*}"; valraw="${stripped#*:}"; val=$(ltrim "$valraw")
        col=$((4 + ${#key} + 2))
        handle_bundle_key "$key" "$val" "$linenum" "$col"
        continue
    fi

    # ===== indent 6: item|option start, or block-list entry =====
    if [ "$indent" -eq 6 ]; then
        [ "$bundle_idx" -ge 0 ] || err "$linenum" 7 "content before any bundle"
        case "$list4" in
            items)
                case "$stripped" in "- "*) ;; *) err "$linenum" 7 "expected item '- name: ...'";; esac
                item_idx=$((item_idx + 1)); cur6="item"
                after="${stripped#- }"
                case "$after" in *:*) ;; *) err "$linenum" 9 "bare value not allowed under 'items:'";; esac
                key="${after%%:*}"; valraw="${after#*:}"; val=$(ltrim "$valraw")
                handle_item_key "$key" "$val" "$linenum" 9;;
            options)
                case "$stripped" in "- "*) ;; *) err "$linenum" 7 "expected option '- name: ...'";; esac
                option_idx=$((option_idx + 1)); cur6="option"
                after="${stripped#- }"
                case "$after" in *:*) ;; *) err "$linenum" 9 "bare value not allowed under 'options:'";; esac
                key="${after%%:*}"; valraw="${after#*:}"; val=$(ltrim "$valraw")
                handle_option_key "$key" "$val" "$linenum" 9;;
            platforms|requires_bundles)
                [ "$bl_active" = 1 ] || err "$linenum" 7 "list entry without an open list"
                case "$stripped" in "- "*) ;; *) err "$linenum" 7 "expected '- value' list entry";; esac
                litem=$(ltrim "${stripped#- }")
                parse_scalar "$litem" "$linenum" 9 || err "$linenum" 9 "empty list entry"
                printf '%s_%d="%s"\n' "$bl_prefix" "$bl_count" "$(shell_escape "$PARSED_VAL")"
                bl_count=$((bl_count + 1));;
            *) err "$linenum" 7 "unexpected indent-6 content (no open items/options/list)";;
        esac
        continue
    fi

    # ===== indent 8: item|option scalar =====
    if [ "$indent" -eq 8 ]; then
        case "$stripped" in *:*) ;; *) err "$linenum" 9 "expected 'key: value'";; esac
        key="${stripped%%:*}"; valraw="${stripped#*:}"; val=$(ltrim "$valraw")
        col=$((8 + ${#key} + 2))
        case "$cur6" in
            item)   handle_item_key "$key" "$val" "$linenum" "$col";;
            option) handle_option_key "$key" "$val" "$linenum" "$col";;
            *) err "$linenum" 9 "unexpected indent-8 content (no open item/option)";;
        esac
        continue
    fi

    err "$linenum" $((indent + 1)) "unexpected indent depth $indent"
done

# Flush any open state at EOF.
if [ "$skip_active" = 1 ]; then
    emit_choice_meta
fi
close_block
close_bundle
printf 'BUNDLE_COUNT=%d\n' $((bundle_idx + 1))
# Success sentinel — MUST be the last line (see CONSUMER CONTRACT above).
printf '__YAML_PARSE_OK=1\n'
