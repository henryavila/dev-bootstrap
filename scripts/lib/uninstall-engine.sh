#!/usr/bin/env bash
# scripts/lib/uninstall-engine.sh — manifest v2 bundle-granularity uninstaller.
#
# Mirror of install-engine.sh (spec D-B3: a separate engine). Removes the
# bundles named in the selection, in REVERSE topological order (dependents
# before their deps), iterating each bundle's items in REVERSE listed order so
# teardown unwinds setup. Honors the same platform + when: gating as install, so
# an item that was never installed (platform mismatch / when: false) is skipped.
#
# It does NOT compute a requires_bundles closure: uninstalling web/valet must
# never auto-remove databases/mysql, which other bundles may still use. Only the
# bundles explicitly listed are removed; reverse-topo just orders them safely
# when several are removed together.
#
# Usage:
#   bash uninstall-engine.sh [--selections FILE] [--bundle topic/bundle ...]
#                            [--topics-dir DIR] [--params FILE] [--secrets FILE]
#                            [--platform OS] [--dry-run]
#
# Per item: dispatch by `type` to scripts/lib/uninstall-handlers.sh
# (_uninstall_<verb>), or, for `type: custom`, source the script and run its
# uninstall() if defined. Deploy items (rendered config) have no package to
# remove; the engine logs them and clears the marker (the user's deployed files
# stay — managed-block teardown is the owning custom script's rollback job).
# The install-state marker is removed regardless, so the menu reflects removal.
#
# Exit codes:
#   0  — all selected bundles processed
#   64 — arg error (no selections / malformed entry / missing bundle)
#   65 — yaml-parse failure or missing sentinel
#   70 — cycle in requires_bundles among selected bundles
#   71 — item when: references an unknown named condition
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MESH_LIB_DIR="$ENGINE_DIR"
# shellcheck disable=SC1091
. "$ENGINE_DIR/log.sh"
# shellcheck disable=SC1091
. "$ENGINE_DIR/env.sh"
# shellcheck disable=SC1091
. "$ENGINE_DIR/uninstall-handlers.sh"
# shellcheck disable=SC1091
. "$ENGINE_DIR/install-state.sh"
# shellcheck disable=SC1091
. "$ENGINE_DIR/conditions.sh"

DRY_RUN=0
SELECTIONS_FILE=""
TOPICS_DIR="$(cd "$ENGINE_DIR/../.." && pwd)/topics"
PARAMS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/mesh/params.env"
SECRETS_FILE_NEW="${XDG_STATE_HOME:-$HOME/.local/state}/mesh/secrets.env"
SECRETS_FILE_LEGACY="$HOME/.local/state/mesh-workstation/secrets.env"
SECRETS_OVERRIDE=""
PLATFORM_OVERRIDE=""
CLI_BUNDLES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --selections)  SELECTIONS_FILE="$2"; shift 2 ;;
        --bundle)      CLI_BUNDLES+=("$2"); shift 2 ;;
        --topics-dir)  TOPICS_DIR="$2"; shift 2 ;;
        --params)      PARAMS_FILE="$2"; shift 2 ;;
        --secrets)     SECRETS_OVERRIDE="$2"; shift 2 ;;
        --platform)    PLATFORM_OVERRIDE="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=1; shift ;;
        --help|-h)     sed -n '2,30p' "$0"; exit 0 ;;
        *)             log_error "unknown arg: $1"; exit 64 ;;
    esac
done

[[ -d "$TOPICS_DIR" ]] || { log_error "missing topics dir: $TOPICS_DIR"; exit 64; }

if [[ -n "$PLATFORM_OVERRIDE" ]]; then
    PLATFORM="$PLATFORM_OVERRIDE"
elif [[ -n "${MESH_OS:-}" ]]; then
    PLATFORM="$MESH_OS"
elif [[ -r "$ENGINE_DIR/../../scripts/lib/detect-os.sh" ]]; then
    PLATFORM="$(bash "$ENGINE_DIR/../../scripts/lib/detect-os.sh")"
elif [[ -r "$ENGINE_DIR/detect-os.sh" ]]; then
    PLATFORM="$(bash "$ENGINE_DIR/detect-os.sh")"
else
    PLATFORM="unknown"
fi
export MESH_OS="$PLATFORM"

# Mirror install-engine: export BREW_PREFIX/BREW_BIN on macOS so custom
# uninstall() scripts that reference them as bare env vars work under set -u.
if [[ "$PLATFORM" == "mac" ]]; then
    __brew_out="$(bash "$ENGINE_DIR/detect-brew.sh" 2>/dev/null || true)"
    if [[ -n "$__brew_out" ]]; then
        eval "$__brew_out"
        export BREW_BIN BREW_PREFIX
    fi
    unset __brew_out
fi

SECRETS_FILES=()
if [[ -n "$SECRETS_OVERRIDE" ]]; then
    SECRETS_FILES=("$SECRETS_OVERRIDE")
else
    [[ -r "$SECRETS_FILE_LEGACY" ]] && SECRETS_FILES+=("$SECRETS_FILE_LEGACY")
    [[ -r "$SECRETS_FILE_NEW" ]]    && SECRETS_FILES+=("$SECRETS_FILE_NEW")
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mesh-uninstall.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ─── selection collection (no closure — see header) ──────────────────────────
SEL_ENTRIES=()
_add_entry() {
    local e="$1"
    case "$e" in */*) : ;; *) log_error "malformed selection (need topic/bundle): $e"; exit 64 ;; esac
    local x
    for x in "${SEL_ENTRIES[@]+"${SEL_ENTRIES[@]}"}"; do [[ "$x" == "$e" ]] && return 0; done
    SEL_ENTRIES+=("$e")
}
if [[ -n "$SELECTIONS_FILE" ]]; then
    [[ -r "$SELECTIONS_FILE" ]] || { log_error "unreadable --selections file: $SELECTIONS_FILE"; exit 64; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        _add_entry "$line"
    done < "$SELECTIONS_FILE"
fi
for b in "${CLI_BUNDLES[@]+"${CLI_BUNDLES[@]}"}"; do _add_entry "$b"; done
[[ "${#SEL_ENTRIES[@]}" -gt 0 ]] || { log_error "no bundles to uninstall (pass --selections FILE or --bundle topic/bundle)"; exit 64; }

# ─── manifest accessors (shared shape with install-engine) ───────────────────
_ensure_topic_parsed() {
    local topic="$1"
    local vf="$WORK/topic__$topic.vars" mf="$TOPICS_DIR/$topic/manifest.yaml"
    [[ -f "$vf" ]] && return 0
    [[ -r "$mf" ]] || { log_error "no manifest for topic: $topic ($mf)"; return 1; }
    bash "$ENGINE_DIR/yaml-parse.sh" < "$mf" > "$vf" || { log_error "yaml-parse failed for topic: $topic"; return 1; }
    grep -q '^__YAML_PARSE_OK=1$' "$vf" || { log_error "yaml-parse sentinel missing for topic: $topic"; return 1; }
}
_bundle_index() {
    local topic="$1" want="$2"
    (
        # shellcheck disable=SC1090
        . "$WORK/topic__$topic.vars"
        local n="${BUNDLE_COUNT:-0}" i nv
        for ((i=0; i<n; i++)); do nv="BUNDLE_${i}_NAME"; [[ "${!nv:-}" == "$want" ]] && { printf '%s' "$i"; exit 0; }; done
        exit 1
    )
}
_bundle_requires() {
    local topic="$1" idx="$2"
    (
        # shellcheck disable=SC1090
        . "$WORK/topic__$topic.vars"
        local cv="BUNDLE_${idx}_REQUIRES_BUNDLES_COUNT" c j ev
        c="${!cv:-0}"
        for ((j=0; j<c; j++)); do ev="BUNDLE_${idx}_REQUIRES_BUNDLES_${j}"; printf '%s\n' "${!ev}"; done
    )
}
_bundle_applies_platform() {
    local topic="$1" idx="$2"
    (
        # shellcheck disable=SC1090
        . "$WORK/topic__$topic.vars"
        local cv="BUNDLE_${idx}_PLATFORMS_COUNT" c j pv
        c="${!cv:-0}"
        [[ "$c" -gt 0 ]] || exit 0
        for ((j=0; j<c; j++)); do pv="BUNDLE_${idx}_PLATFORMS_${j}"; [[ "${!pv:-}" == "$PLATFORM" ]] && exit 0; done
        exit 1
    )
}
_topic_order() {
    (
        # shellcheck disable=SC1090
        . "$WORK/topic__$1.vars"
        printf '%s' "${TOPIC_ORDER:-9999}"
    )
}
_in_list() { local n="$1"; shift; local x; for x in "$@"; do [[ "$x" == "$n" ]] && return 0; done; return 1; }

# Parse every selected topic + verify each bundle exists.
for entry in "${SEL_ENTRIES[@]}"; do
    topic="${entry%%/*}"; bundle="${entry#*/}"
    _ensure_topic_parsed "$topic" || exit 65
    _bundle_index "$topic" "$bundle" >/dev/null || { log_error "bundle does not exist: $entry"; exit 64; }
done

# ─── order: install topo order, then reversed ────────────────────────────────
_sorted=()
while IFS= read -r _e; do [[ -n "$_e" ]] && _sorted+=("$_e"); done < <(
    for entry in "${SEL_ENTRIES[@]}"; do
        topic="${entry%%/*}"; bundle="${entry#*/}"
        idx="$(_bundle_index "$topic" "$bundle")"
        printf '%06d:%03d\t%s\n' "$(_topic_order "$topic")" "$idx" "$entry"
    done | sort | cut -f2-
)
SEL_ENTRIES=("${_sorted[@]}")

ORDERED=()
remaining=("${SEL_ENTRIES[@]}")
while [[ "${#remaining[@]}" -gt 0 ]]; do
    progressed=0
    leftover=()
    for entry in "${remaining[@]}"; do
        topic="${entry%%/*}"; bundle="${entry#*/}"
        idx="$(_bundle_index "$topic" "$bundle")"
        deps_ok=1
        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            _in_list "$dep" "${SEL_ENTRIES[@]+"${SEL_ENTRIES[@]}"}" || continue
            _in_list "$dep" "${ORDERED[@]+"${ORDERED[@]}"}" || deps_ok=0
        done < <(_bundle_requires "$topic" "$idx")
        if [[ "$deps_ok" -eq 1 ]]; then ORDERED+=("$entry"); progressed=1; else leftover+=("$entry"); fi
    done
    remaining=("${leftover[@]+"${leftover[@]}"}")
    [[ "$progressed" -eq 0 ]] && { log_error "cycle in requires_bundles among: ${remaining[*]}"; exit 70; }
done

# Reverse install order → uninstall order (dependents before deps).
UNINSTALL_ORDER=()
for ((k=${#ORDERED[@]}-1; k>=0; k--)); do UNINSTALL_ORDER+=("${ORDERED[$k]}"); done

# ─── per-bundle uninstall ─────────────────────────────────────────────────────
uninstall_bundle() {
    local topic="$1" bundle="$2"
    local B; B="$(_bundle_index "$topic" "$bundle")"
    local TOPIC="$topic"
    cd "$TOPICS_DIR/$topic" || { log_error "$topic: cannot cd into topic dir"; exit 64; }

    # shellcheck disable=SC1090
    . "$WORK/topic__$topic.vars"

    # Source persisted option values (for when: option.X resolution + custom
    # uninstall() scripts), normalize toggles to 1/0.
    set -a
    if [[ -r "$PARAMS_FILE" ]]; then
        # shellcheck disable=SC1090
        . "$PARAMS_FILE" || log_warn "$topic: could not source params"
    fi
    local sf
    for sf in "${SECRETS_FILES[@]+"${SECRETS_FILES[@]}"}"; do
        # shellcheck disable=SC1090
        . "$sf" 2>/dev/null || log_warn "$topic: could not source secrets ($sf)"
    done
    set +a
    local optc_var="BUNDLE_${B}_OPTION_COUNT" optc o
    optc="${!optc_var:-0}"
    for ((o=0; o<optc; o++)); do
        local oe_var="BUNDLE_${B}_OPTION_${o}_ENV" ot_var="BUNDLE_${B}_OPTION_${o}_TYPE"
        local oe="${!oe_var:-}" ot="${!ot_var:-}"
        [[ -n "$oe" && "$ot" == "toggle" ]] || continue
        case "${!oe:-}" in 1|true|yes|on|TRUE|True|Yes|On) export "$oe=1" ;; *) export "$oe=0" ;; esac
    done

    _option_is_on() {
        local oname="$1" oc_var="BUNDLE_${B}_OPTION_COUNT" oc i
        oc="${!oc_var:-0}"
        for ((i=0; i<oc; i++)); do
            local nv="BUNDLE_${B}_OPTION_${i}_NAME"
            if [[ "${!nv:-}" == "$oname" ]]; then
                local ev="BUNDLE_${B}_OPTION_${i}_ENV"; local e="${!ev:-}"; [[ -n "$e" ]] || return 1
                case "${!e:-}" in 1|true|yes|on|TRUE|True|Yes|On) return 0 ;; *) return 1 ;; esac
            fi
        done
        return 1
    }

    local icount_var="BUNDLE_${B}_ITEM_COUNT" icount i
    icount="${!icount_var:-0}"
    local removed=0
    for ((i=icount-1; i>=0; i--)); do   # reverse listed order
        local p="BUNDLE_${B}_ITEM_${i}"
        local name="${p}_NAME";     name="${!name:-}"
        local type="${p}_TYPE";     type="${!type:-}"
        local spec="${p}_SPEC";     spec="${!spec:-}"
        local script="${p}_SCRIPT"; script="${!script:-}"
        local when="${p}_WHEN";     when="${!when:-}"
        [[ -n "$name" ]] || continue

        # platform gate (item was never installed off-platform)
        local pc_var="${p}_PLATFORMS_COUNT" pc j ok=1
        pc="${!pc_var:-0}"
        if [[ "$pc" -gt 0 ]]; then
            ok=0
            for ((j=0; j<pc; j++)); do local pe="${p}_PLATFORMS_${j}"; [[ "${!pe:-}" == "$PLATFORM" ]] && { ok=1; break; }; done
            [[ "$ok" -eq 1 ]] || { log_info "$bundle/$name: skip uninstall (platform mismatch)"; continue; }
        fi
        # when gate (item was never installed when condition false)
        if [[ -n "$when" ]]; then
            case "$when" in
                option.*) _option_is_on "${when#option.}" || { log_info "$bundle/$name: skip uninstall (when: $when off)"; continue; } ;;
                *)
                    local _wrc=0; cond_eval "$when" || _wrc=$?
                    if [[ "$_wrc" -eq 2 ]]; then log_error "$bundle/$name: when: unknown condition '$when'"; exit 71
                    elif [[ "$_wrc" -ne 0 ]]; then log_info "$bundle/$name: skip uninstall (when: $when false)"; continue; fi ;;
            esac
        fi

        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[dry-run] would uninstall: $bundle/$name (type=$type)"
            removed=$((removed+1)); continue
        fi

        case "$type" in
            brew-formula)  _uninstall_brew "$spec" ;;
            brew-cask)     _uninstall_brew_cask "$spec" ;;
            apt)           _uninstall_apt "$spec" ;;
            npm-global)    _uninstall_npm_global "$spec" ;;
            cargo)         _uninstall_cargo "$spec" ;;
            pip)           _uninstall_pip "$spec" ;;
            npx)           _uninstall_npx "$spec" ;;
            git-clone)     _uninstall_clone "$spec" ;;
            deploy)        log_info "$bundle/$name: deploy item — rendered files left in place (clearing marker)" ;;
            custom)
                if [[ -n "$script" && -r "$script" ]]; then
                    (
                        # shellcheck disable=SC1090
                        . "$script"
                        if declare -f uninstall >/dev/null 2>&1; then uninstall
                        else warn "$bundle/$name: custom script defines no uninstall() — remove manually"; fi
                    ) || log_warn "$bundle/$name: uninstall() returned non-zero (continuing)"
                else
                    warn "$bundle/$name: custom script not found: ${script:-<unset>}"
                fi
                ;;
            *) warn "$bundle/$name: no uninstall handler for type=$type" ;;
        esac

        # Drop the marker regardless: the user's intent (removal) is recorded
        # here whether or not the package was already gone.
        install_state_remove "$TOPIC" "$name" 2>/dev/null || true
        removed=$((removed+1))
    done
    log_info "$topic/$bundle: uninstalled ($removed item(s) on $PLATFORM)"
}

bundles_done=0
bundles_skipped=0
for entry in "${UNINSTALL_ORDER[@]}"; do
    topic="${entry%%/*}"; bundle="${entry#*/}"
    idx="$(_bundle_index "$topic" "$bundle")"
    if ! _bundle_applies_platform "$topic" "$idx"; then
        log_info "$entry: skip bundle (platforms: excludes $PLATFORM)"
        bundles_skipped=$((bundles_skipped+1))
        continue
    fi
    ( uninstall_bundle "$topic" "$bundle" ) || { _rc=$?; log_error "$entry: bundle uninstall failed (rc=$_rc)"; exit $_rc; }
    bundles_done=$((bundles_done+1))
done

if (( bundles_skipped > 0 )); then
    log_info "uninstall-engine: removed $bundles_done bundle(s) on $PLATFORM ($bundles_skipped skipped by platforms:)"
else
    log_info "uninstall-engine: removed $bundles_done bundle(s) on $PLATFORM"
fi
