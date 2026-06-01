#!/usr/bin/env bash
# validate-manifest.sh — lint manifest.yaml v2 against the spec's §8 rules.
#
# Usage:
#   validate-manifest.sh [TOPIC_DIR | MANIFEST_FILE ...]
#   (no args → validates every topics/*/manifest.yaml in the repo)
#
# Reads each manifest through yaml-parse.sh in META mode (MESH_YAML_META=1) so
# the UI-only choices/derive_from/source metadata needed by the cross-reference
# rules is available, then enforces docs/2026-05-28-mesh-manifest-v2-spec.md §8:
#
#   Hard errors  (rules 1-19)  → manifest rejected, exit code = #errors.
#   Soft warnings              → reported, do not fail the run.
#
# Cross-manifest rules (9 requires_bundles target exists, 10 cycle) need every
# topic/bundle in scope, so the run is two passes: build a registry of all
# topic/bundles, then validate each manifest against it. During the migration a
# `requires_bundles` pointing at a topic that has no manifest.yaml yet (e.g.
# web → languages/php before languages is migrated) is a WARNING, not an error
# (forward-ref tolerance, per the F9.6 handoff). Pass --strict to promote those
# to errors once every topic is migrated.
#
# Bash 3.2 floor. eval is used on yaml-parse.sh output per its sentinel
# contract; manifests are isolated in subshells so their vars don't bleed.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PARSER="$HERE/yaml-parse.sh"

# cond_is_known backs §8 rule 13 (when: <named condition>).
# shellcheck source=/dev/null
. "$HERE/conditions.sh"

STRICT=0
args=()
for a in "$@"; do
    case "$a" in
        --strict) STRICT=1 ;;
        *) args+=("$a") ;;
    esac
done

# --- collect manifests -------------------------------------------------------
manifests=()
if [ "${#args[@]}" -gt 0 ]; then
    for a in "${args[@]}"; do
        if [ -d "$a" ]; then
            manifests+=("$a/manifest.yaml")
        elif [ -f "$a" ]; then
            manifests+=("$a")
        else
            printf 'validate-manifest: no such path: %s\n' "$a" >&2
            exit 2
        fi
    done
else
    for m in "$ROOT"/topics/*/manifest.yaml; do
        [ -f "$m" ] && manifests+=("$m")
    done
fi

if [ "${#manifests[@]}" -eq 0 ]; then
    printf 'validate-manifest: no manifest.yaml found\n' >&2
    exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mesh-validate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
REG="$TMP/registry"      # topic/bundle per line
TOPICS_SEEN="$TMP/topics" # topic per line
EDGES="$TMP/edges"       # "src dst" per line (topic/bundle pairs)
FIND="$TMP/findings"     # "LEVEL<TAB>scope<TAB>message" per line
: > "$REG"; : > "$TOPICS_SEEN"; : > "$EDGES"; : > "$FIND"

topic_of() { basename "$(dirname "$1")"; }

# --- pass A: registry + dependency edges -------------------------------------
emit_registry() {
    local m="$1" topic="$2" out
    out="$(MESH_YAML_META=1 "$PARSER" < "$m" 2>/dev/null)" || { echo "PARSEFAIL"; return; }
    (
        eval "$out"
        [ "${__YAML_PARSE_OK:-0}" = 1 ] || { echo "PARSEFAIL"; exit 0; }
        echo "TOPIC $topic"
        local b=0 name rc j dep
        while [ "$b" -lt "${BUNDLE_COUNT:-0}" ]; do
            eval "name=\${BUNDLE_${b}_NAME:-}"
            [ -n "$name" ] && echo "BUNDLE $topic/$name"
            eval "rc=\${BUNDLE_${b}_REQUIRES_BUNDLES_COUNT:-0}"
            j=0
            while [ "$j" -lt "$rc" ]; do
                eval "dep=\${BUNDLE_${b}_REQUIRES_BUNDLES_${j}:-}"
                [ -n "$name" ] && [ -n "$dep" ] && echo "EDGE $topic/$name $dep"
                j=$((j + 1))
            done
            b=$((b + 1))
        done
    )
}

mi=0
while [ "$mi" -lt "${#manifests[@]}" ]; do
    m="${manifests[$mi]}"; topic="$(topic_of "$m")"
    while IFS=' ' read -r kind a b; do
        case "$kind" in
            TOPIC)  echo "$a" >> "$TOPICS_SEEN" ;;
            BUNDLE) echo "$a" >> "$REG" ;;
            EDGE)   echo "$a $b" >> "$EDGES" ;;
            PARSEFAIL) printf 'ERROR\t%s\tyaml-parse.sh rejected the manifest (run it directly to see the error)\n' "$topic" >> "$FIND" ;;
        esac
    done < <(emit_registry "$m" "$topic")
    mi=$((mi + 1))
done

# --- cross rule 9: requires_bundles targets ----------------------------------
if [ -s "$EDGES" ]; then
    while IFS=' ' read -r src dst; do
        [ -n "$dst" ] || continue
        if grep -qxF "$dst" "$REG"; then
            continue
        fi
        dep_topic="${dst%%/*}"
        srctopic="${src%%/*}"
        if grep -qxF "$dep_topic" "$TOPICS_SEEN"; then
            printf 'ERROR\t%s\t%s requires_bundles %s — topic exists but bundle does not\n' "$srctopic" "$src" "$dst" >> "$FIND"
        elif [ "$STRICT" = 1 ]; then
            printf 'ERROR\t%s\t%s requires_bundles %s — target topic not present\n' "$srctopic" "$src" "$dst" >> "$FIND"
        else
            printf 'WARN\t%s\t%s requires_bundles %s — forward-ref (topic not migrated yet)\n' "$srctopic" "$src" "$dst" >> "$FIND"
        fi
    done < "$EDGES"
fi

# --- cross rule 10: requires_bundles cycle (Kahn over resolvable edges) -------
if [ -s "$EDGES" ]; then
    remaining=" $(awk '{print $1; print $2}' "$EDGES" | sort -u | tr '\n' ' ')"
    changed=1
    while [ "$changed" = 1 ]; do
        case "$remaining" in *[!\ ]*) ;; *) break ;; esac
        changed=0
        newr=" "
        for n in $remaining; do
            hasdep=0
            for d in $(awk -v s="$n" '$1==s{print $2}' "$EDGES"); do
                case "$remaining" in *" $d "*) hasdep=1; break ;; esac
            done
            if [ "$hasdep" = 1 ]; then newr="$newr$n "; else changed=1; fi
        done
        remaining="$newr"
    done
    rem="$(printf '%s' "$remaining" | tr -s ' ')"
    rem="${rem# }"; rem="${rem% }"
    if [ -n "$rem" ]; then
        printf 'ERROR\t<cross>\trequires_bundles cycle among: %s\n' "$rem" >> "$FIND"
    fi
fi

# --- pass B: per-manifest structural + reference rules -----------------------
validate_one() {
    local m="$1" topic="$2" out
    out="$(MESH_YAML_META=1 "$PARSER" < "$m" 2>/dev/null)" || return 0
    (
        eval "$out"
        [ "${__YAML_PARSE_OK:-0}" = 1 ] || exit 0
        E() { printf 'ERROR\t%s\t%s\n' "$topic" "$1"; }
        W() { printf 'WARN\t%s\t%s\n' "$topic" "$1"; }

        # Rule 1 — topic essentials.
        [ -n "${TOPIC_LABEL:-}" ] || E "topic.label missing"
        [ -n "${TOPIC_ORDER:-}" ] || E "topic.order missing"
        [ "${BUNDLE_COUNT:-0}" -gt 0 ] || E "bundles[] missing or empty"
        if [ -n "${TOPIC_HINT:-}" ] && [ "${#TOPIC_HINT}" -gt 60 ]; then
            W "topic.hint > 60 chars (${#TOPIC_HINT})"
        fi

        local seen_bundles=" " b=0
        while [ "$b" -lt "${BUNDLE_COUNT:-0}" ]; do
            local bn bl bd bic breq bds
            eval "bn=\${BUNDLE_${b}_NAME:-}"
            eval "bl=\${BUNDLE_${b}_LABEL:-}"
            eval "bd=\${BUNDLE_${b}_DESC:-}"
            eval "bic=\${BUNDLE_${b}_ITEM_COUNT:-0}"
            eval "breq=\${BUNDLE_${b}_REQUIRED:-0}"
            eval "bds=\${BUNDLE_${b}_DEFAULT_SELECTED:-1}"
            local tag="bundle[$b]"; [ -n "$bn" ] && tag="bundle '$bn'"

            # Rule 2 — bundle essentials.
            [ -n "$bn" ] || E "$tag: name missing"
            [ -n "$bl" ] || E "$tag: label missing"
            [ -n "$bd" ] || E "$tag: desc missing"
            [ "$bic" -gt 0 ] || E "$tag: items[] missing or empty"
            # Rule 6 — unique bundle name within topic.
            if [ -n "$bn" ]; then
                case "$seen_bundles" in *" $bn "*) E "$tag: duplicate bundle name" ;; esac
                seen_bundles="$seen_bundles$bn "
            fi
            # Rule 18 — required ⇒ not default-off.
            [ "$breq" = 1 ] && [ "$bds" = 0 ] && E "$tag: required:true with default_selected:false (contradiction)"
            # Soft — desc length + opt-in hint.
            [ -n "$bd" ] && [ "${#bd}" -gt 80 ] && W "$tag: desc > 80 chars (${#bd}) — truncation risk"

            # --- options pass (must precede items: when: option.X needs them) ---
            local ocount; eval "ocount=\${BUNDLE_${b}_OPTION_COUNT:-0}"
            local seen_opts=" " seen_envs=" " opt_names=" " toggle_names=" " o=0
            while [ "$o" -lt "$ocount" ]; do
                local oname otype oenv odf dfrom osrc haschoices cdef rmin ddc dsc
                eval "oname=\${BUNDLE_${b}_OPTION_${o}_NAME:-}"
                eval "otype=\${BUNDLE_${b}_OPTION_${o}_TYPE:-}"
                eval "oenv=\${BUNDLE_${b}_OPTION_${o}_ENV:-}"
                eval "odf=\${BUNDLE_${b}_OPTION_${o}_DEFAULT_FROM:-}"
                eval "dfrom=\${BUNDLE_${b}_OPTION_${o}_DERIVE_FROM:-}"
                eval "osrc=\${BUNDLE_${b}_OPTION_${o}_SOURCE:-}"
                eval "haschoices=\${BUNDLE_${b}_OPTION_${o}_HAS_CHOICES:-0}"
                eval "cdef=\${BUNDLE_${b}_OPTION_${o}_CHOICE_DEFAULT_COUNT:-0}"
                eval "rmin=\${BUNDLE_${b}_OPTION_${o}_REQUIRED_MIN:-}"
                eval "ddc=\${BUNDLE_${b}_OPTION_${o}_DEFAULT_COUNT:-}"
                eval "dsc=\${BUNDLE_${b}_OPTION_${o}_DEFAULT+x}"
                local otag="$tag option[$o]"; [ -n "$oname" ] && otag="$tag option '$oname'"

                [ -n "$oname" ] || E "$otag: option name missing"
                [ -n "$otype" ] || E "$otag: option type missing"
                [ -n "$oenv" ]  || E "$otag: option env missing"
                if [ -n "$oname" ]; then
                    case "$seen_opts" in *" $oname "*) E "$otag: duplicate option name" ;; esac  # Rule 8
                    seen_opts="$seen_opts$oname "
                    opt_names="$opt_names$oname "
                    [ "$otype" = toggle ] && toggle_names="$toggle_names$oname "
                fi
                if [ -n "$oenv" ]; then
                    case "$seen_envs" in *" $oenv "*) E "$otag: duplicate option env '$oenv'" ;; esac  # Rule 17
                    seen_envs="$seen_envs$oenv "
                fi
                # Rule 19 — default_from only on text.
                [ -n "$odf" ] && [ "$otype" != text ] && E "$otag: default_from on non-text option (type '$otype')"
                # Rule 15 — choices/derive_from/source mutually exclusive.
                local nsel=0
                [ "$haschoices" = 1 ] && nsel=$((nsel + 1))
                [ -n "$dfrom" ] && nsel=$((nsel + 1))
                [ -n "$osrc" ] && nsel=$((nsel + 1))
                [ "$nsel" -gt 1 ] && E "$otag: more than one of choices/derive_from/source set"
                # Rule 16 — derive_from/source only on select/multiselect.
                if [ -n "$dfrom" ] || [ -n "$osrc" ]; then
                    case "$otype" in select|multiselect) ;; *) E "$otag: derive_from/source on non-select option (type '$otype')" ;; esac
                fi
                # Rule 14 — multiselect required_min must not exceed pre-selected defaults.
                if [ "$otype" = multiselect ] && [ -n "$rmin" ] && [ "$rmin" -gt 0 ]; then
                    local dcnt=0
                    if [ "$haschoices" = 1 ]; then dcnt="$cdef"
                    elif [ -n "$ddc" ]; then dcnt="$ddc"
                    elif [ "$dsc" = x ]; then dcnt=1
                    fi
                    [ "$rmin" -gt "$dcnt" ] && E "$otag: required_min ($rmin) exceeds pre-selected defaults ($dcnt)"
                fi
                o=$((o + 1))
            done
            # Rule 11 — derive_from references an existing option (re-scan: may target a later option).
            o=0
            while [ "$o" -lt "$ocount" ]; do
                local dfrom2 oname2
                eval "dfrom2=\${BUNDLE_${b}_OPTION_${o}_DERIVE_FROM:-}"
                eval "oname2=\${BUNDLE_${b}_OPTION_${o}_NAME:-}"
                if [ -n "$dfrom2" ]; then
                    case "$opt_names" in
                        *" $dfrom2 "*) ;;
                        *) E "$tag option '$oname2': derive_from '$dfrom2' references unknown option" ;;
                    esac
                fi
                o=$((o + 1))
            done

            # --- items pass ---
            local seen_items=" " i=0
            while [ "$i" -lt "$bic" ]; do
                local iname itype iscript ispec iwhen itier
                eval "iname=\${BUNDLE_${b}_ITEM_${i}_NAME:-}"
                eval "itype=\${BUNDLE_${b}_ITEM_${i}_TYPE:-}"
                eval "iscript=\${BUNDLE_${b}_ITEM_${i}_SCRIPT:-}"
                eval "ispec=\${BUNDLE_${b}_ITEM_${i}_SPEC:-}"
                eval "iwhen=\${BUNDLE_${b}_ITEM_${i}_WHEN:-}"
                eval "itier=\${BUNDLE_${b}_ITEM_${i}_UNINSTALL_TIER:-}"
                local itag="$tag item[$i]"; [ -n "$iname" ] && itag="$tag item '$iname'"

                # Rule 3 — item essentials.
                [ -n "$iname" ] || E "$itag: name missing"
                [ -n "$itype" ] || E "$itag: type missing"
                # Rules 4/5 — driver argument.
                if [ "$itype" = custom ]; then
                    [ -n "$iscript" ] || E "$itag: type custom requires script"
                elif [ -n "$itype" ]; then
                    [ -n "$ispec" ] || E "$itag: type '$itype' requires spec"
                    case "$itype" in
                        brew-formula|brew-cask|apt|npm-global|npx|cargo|pip|git-clone|github-release|go-install) ;;
                        *) W "$itag: unknown driver type '$itype'" ;;
                    esac
                fi
                # Rule 7 — unique item name within bundle.
                if [ -n "$iname" ]; then
                    case "$seen_items" in *" $iname "*) E "$itag: duplicate item name" ;; esac
                    seen_items="$seen_items$iname "
                fi
                # Rules 12/13 — when: resolution.
                if [ -n "$iwhen" ]; then
                    case "$iwhen" in
                        option.*)
                            local optref="${iwhen#option.}"
                            case "$opt_names" in
                                *" $optref "*)
                                    case "$toggle_names" in
                                        *" $optref "*) ;;
                                        *) E "$itag: when option.$optref targets a non-toggle option" ;;
                                    esac ;;
                                *) E "$itag: when option.$optref targets unknown option" ;;
                            esac ;;
                        *)
                            cond_is_known "$iwhen" || E "$itag: when '$iwhen' is not a defined named condition" ;;
                    esac
                fi
                # Soft — uninstall_tier range.
                if [ -n "$itier" ]; then
                    case "$itier" in 0|1|2|3) ;; *) W "$itag: uninstall_tier $itier outside 0-3" ;; esac
                fi
                i=$((i + 1))
            done

            b=$((b + 1))
        done
    )
}

mi=0
while [ "$mi" -lt "${#manifests[@]}" ]; do
    m="${manifests[$mi]}"; topic="$(topic_of "$m")"
    validate_one "$m" "$topic" >> "$FIND"
    mi=$((mi + 1))
done

# --- report ------------------------------------------------------------------
# grep -c prints 0 (and exits 1) when there are no matches; the exit code is
# discarded by command substitution, so no `|| echo 0` (that would double it).
errors=$(grep -c '^ERROR' "$FIND")
warns=$(grep -c '^WARN' "$FIND")

if [ "$warns" -gt 0 ]; then
    while IFS=$'\t' read -r lvl scope msg; do
        [ "$lvl" = WARN ] && printf 'warn   [%s] %s\n' "$scope" "$msg" >&2
    done < "$FIND"
fi
if [ "$errors" -gt 0 ]; then
    while IFS=$'\t' read -r lvl scope msg; do
        [ "$lvl" = ERROR ] && printf 'ERROR  [%s] %s\n' "$scope" "$msg" >&2
    done < "$FIND"
fi

printf 'validate-manifest: %d manifest(s), %d error(s), %d warning(s)\n' \
    "${#manifests[@]}" "$errors" "$warns" >&2

[ "$errors" -gt 125 ] && exit 125
exit "$errors"
