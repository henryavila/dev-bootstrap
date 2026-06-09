#!/usr/bin/env bash
# scripts/lib/install-engine.sh — manifest v2 bundle-granularity install engine.
#
# Consumes the hierarchical manifest.yaml v2 schema (topic → bundles → items +
# options) via yaml-parse.sh v2. The unit of selection is the BUNDLE; items
# inside a bundle are atomic (spec D-5). Selected bundles are installed in
# topological order by `requires_bundles:` (deps first, spec §5.1).
#
# Usage:
#   bash install-engine.sh [--selections FILE] [--bundle topic/bundle ...]
#                          [--topics-dir DIR] [--params FILE] [--secrets FILE]
#                          [--platform OS] [--non-interactive] [--dry-run]
#                          [--update | --repair | --adopt]
#
# Selections come from --selections (one `topic/bundle` per line; blank lines
# and `#` comments ignored) and/or repeated --bundle flags. The two combine.
#
# --update (T-600): instead of install-if-missing, run each installed item's
# version-aware <type>_update (upgrade only if stale), gated by opt-in update
# categories derived from the topic — agent-clis (ai), runtimes-dbs (languages,
# databases), cli-tools (everything else). Switches MESH_UPDATE_AGENT_CLIS /
# MESH_UPDATE_RUNTIMES_DBS / MESH_UPDATE_CLI_TOOLS default OFF (params.env/env).
# Never installs new items; items without a driver updater (deploy, …) are
# skipped. `mesh update` invokes this after `git pull`.
#
# --repair (verify/operational plan §C): a precise verify+repair sweep over the
# selected/installed bundles. For each non-idempotent INSTALLED item (install
# marker present) it runs the item's STRONGEST probe (driver verify > manifest
# check > driver check) — NOT the weak keep/skip check — and, when that fails,
# runs ONE repair through the installer (driver <type>_repair, else <type>_install;
# brew is reinstall-aware; custom only if it defines repair()) then re-probes.
# A failure is recorded and the sweep CONTINUES (reports every broken item in one
# pass) — rc 67 if any item is left unresolved, rc 0 on a healthy tree. Mutually
# exclusive with --update. `mesh doctor --fix` / `setup --repair` invoke it.
#
# --adopt (scanner-marker-coherence handoff §A): a READ-ONLY marker backfill. For
# each marker-ABSENT item whose strongest probe passes (driver verify > manifest
# check > driver check) it writes the install marker WITHOUT install/deploy/sudo.
# Reconciles the drift-in state a v1-migrated (or foreign) install leaves — tool
# present but no v2 marker — so the marker-only menu scanner stops reporting it
# `missing`. The inverse of --repair (which acts on marker-PRESENT items): same
# probe, marker-ABSENT target, and the marker is its only write. Idempotent / a
# tool that simply isn't installed are no-ops; absent ≠ error so it always exits
# 0 and is safe to re-run. Mutually exclusive with --update/--repair. `mesh adopt`
# / `setup --adopt` invoke it. (`--dry-run` short-circuits before the probe, like
# the other modes — use `mesh adopt` itself, it is already side-effect-free.)
#
# Per bundle, in topological order:
#   1. cd into the topic dir (custom `script:` paths are topic-relative).
#   2. Source params.env (resolved non-secret options) + secrets.env, then
#      export each option's `env`. Under --non-interactive, apply each option's
#      schema default (toggle/select/text scalar; multiselect default list;
#      text `default_from:` command) for any value still unset.
#   3. For each item IN LISTED ORDER:
#        - gate on `platforms:` (item-level, then inherits nothing — bundle
#          platforms gate the whole bundle earlier);
#        - eval `when:` — `option.<x>` resolves the toggle's env value;
#          a bare name resolves via conditions.sh `cond_eval` (rc 2 = hard error);
#        - dispatch by `type` (custom → source script + check/install/verify;
#          driver types → installers/<type>.sh);
#        - `idempotent: true` items skip the pre-check and post-verify and
#          always run (spec §11 — e.g. the syncthing apply-pause banner);
#        - on success write the install marker (install_state_record).
#
# Lifecycle per non-idempotent item (spec §C17):
#   check → install (if check fails) → verify (fallback check) → post → rollback.
# Subshell isolation: each bundle (and each item within it) runs in `(...)` so
# functions/vars don't leak across bundles or items.
#
# Platform filter:
#   Current platform resolved from --platform > $MESH_OS > detect-os.sh.
#   Bundle/item with non-empty `platforms:` runs ONLY if the current platform is
#   listed; empty/missing `platforms:` applies everywhere (spec C17).
#
# Exit codes:
#   0  — all selected bundles processed successfully
#   64 — arg error (missing/invalid flag, no selections, malformed entry)
#   65 — yaml-parse failure or missing sentinel (__YAML_PARSE_OK)
#   66 — no driver found for an item type
#   67 — verify failed (rollback was called if present)
#   68 — post-install check failed (no verify function defined)
#   69 — post: hook failed (rollback was called if present)
#   70 — cycle in requires_bundles among selected bundles
#   71 — item `when:` references an unknown named condition (conditions.sh rc 2)
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Canonical scripts/lib dir, exported so drivers (e.g. the deploy driver, which
# needs scripts/lib/deploy.sh) can resolve sibling libs without fragile
# BASH_SOURCE/cwd gymnastics inside per-item subshells.
export MESH_LIB_DIR="$ENGINE_DIR"
# shellcheck disable=SC1091
. "$ENGINE_DIR/log.sh"
# shellcheck disable=SC1091
. "$ENGINE_DIR/env.sh"
# shellcheck disable=SC1091
. "$ENGINE_DIR/install-state.sh"
# shellcheck disable=SC1091
. "$ENGINE_DIR/conditions.sh"
# shellcheck disable=SC1091
. "$ENGINE_DIR/state-dir.sh"

DRY_RUN=0
SELECTIONS_FILE=""
TOPICS_DIR="$(cd "$ENGINE_DIR/../.." && pwd)/topics"
INSTALLERS_DIR="$ENGINE_DIR/installers"
PARAMS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/mesh/params.env"
SECRETS_FILE_NEW="${XDG_STATE_HOME:-$HOME/.local/state}/mesh/secrets.env"
SECRETS_OVERRIDE=""
PLATFORM_OVERRIDE=""
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
UPDATE_MODE=0
REPAIR_MODE=0
ADOPT_MODE=0
CLI_BUNDLES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --selections)       SELECTIONS_FILE="$2"; shift 2 ;;
        --bundle)           CLI_BUNDLES+=("$2"); shift 2 ;;
        --topics-dir)       TOPICS_DIR="$2"; shift 2 ;;
        --installers-dir)   INSTALLERS_DIR="$2"; shift 2 ;;
        --params)           PARAMS_FILE="$2"; shift 2 ;;
        --secrets)          SECRETS_OVERRIDE="$2"; shift 2 ;;
        --platform)         PLATFORM_OVERRIDE="$2"; shift 2 ;;
        --non-interactive)  NON_INTERACTIVE=1; shift ;;
        --dry-run)          DRY_RUN=1; shift ;;
        --update)           UPDATE_MODE=1; shift ;;
        --repair)           REPAIR_MODE=1; shift ;;
        --adopt)            ADOPT_MODE=1; shift ;;
        --help|-h)          sed -n '2,40p' "$0"; exit 0 ;;
        *)                  log_error "unknown arg: $1"; exit 64 ;;
    esac
done

# --update / --repair / --adopt are pairwise exclusive: each replaces the normal
# install lifecycle with a different single-purpose pass — --update upgrades
# versions, --repair runs an operational verify+fix, --adopt does a read-only
# marker backfill. Combining any two is a usage error (plan §3.C / Codex finding
# #7 / scanner-marker-coherence handoff).
_mode_count=$(( UPDATE_MODE + REPAIR_MODE + ADOPT_MODE ))
if [[ "$_mode_count" -gt 1 ]]; then
    log_error "--update, --repair and --adopt are mutually exclusive"
    exit 64
fi

[[ -d "$TOPICS_DIR" ]]     || { log_error "missing topics dir: $TOPICS_DIR"; exit 64; }
[[ -d "$INSTALLERS_DIR" ]] || { log_error "missing installers dir: $INSTALLERS_DIR"; exit 64; }

# Resolve current platform: --platform > $MESH_OS > detect-os.sh > "unknown".
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

# On macOS, many custom item scripts reference $BREW_PREFIX/$BREW_BIN as bare
# env vars (v1 setup.sh exported them globally; the v2 engine must too, mirroring
# MESH_LIB_DIR). Detect Homebrew once and export so every item subshell inherits
# them. Tolerant: if brew isn't on disk yet (e.g. a fresh machine before
# foundation/base installs it) we leave them unset — foundation/mac/core.sh
# self-resolves via detect-brew.sh, and later bundles re-run the engine with brew
# present. Items that need brew but run before it exists fail loudly under set -u,
# which is correct (topo order puts foundation first anyway).
if [[ "$PLATFORM" == "mac" ]]; then
    __brew_out="$(bash "$ENGINE_DIR/detect-brew.sh" 2>/dev/null || true)"
    if [[ -n "$__brew_out" ]]; then
        eval "$__brew_out"
        export BREW_BIN BREW_PREFIX
        # Put Homebrew's bin/sbin on PATH for EVERY item subshell so the package
        # drivers (brew_formula_check runs `brew list`, …) AND custom scripts can
        # resolve brew-installed tools (brew, fnm, node, cargo…) by BARE name,
        # consistently — independent of how setup.sh was invoked or whether the
        # prefix is standard (/opt/homebrew, /usr/local) or custom (e.g.
        # /Volumes/External/homebrew). Without this a bare `fnm`/`brew` lookup
        # fails whenever the invoking shell's PATH lacks the prefix, and a custom
        # verify() then reports rc=67 although the tool is in fact installed.
        # Idempotent (skip when already on PATH).
        if [[ -n "${BREW_PREFIX:-}" && ":$PATH:" != *":$BREW_PREFIX/bin:"* ]]; then
            PATH="$BREW_PREFIX/bin:$BREW_PREFIX/sbin:$PATH"; export PATH
        fi
    fi
    unset __brew_out
fi

# Standard user bin: many non-brew installers (rtk, moshi-hook, github-release
# binaries, the WSL rust bins, pip --user) drop executables in ~/.local/bin.
# Put it on PATH for EVERY item subshell — on mac AND wsl, not just mac — so a
# bare-name verify()/check() resolves a correctly-installed tool there, the same
# rationale as the Homebrew prepend above. Without it a custom verify() reports
# rc=67 (which aborts the WHOLE run) although the binary is in fact installed.
# Idempotent (skip when already on PATH). Per-script absolute fallbacks remain
# the belt-and-suspenders for tools outside this dir (~/.atuin/bin, fnm shims).
if [[ -d "$HOME/.local/bin" && ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    PATH="$HOME/.local/bin:$PATH"; export PATH
fi

# ── update mode (T-600): opt-in category gating ──────────────────────────────
# `mesh update` runs the engine with --update: each installed item is upgraded
# (version-aware, via the driver's <type>_update) ONLY if its category is opted
# in. Categories are derived from the topic (granularity C / D-U4); the three
# opt-in switches default OFF, read from params.env or the environment.
_update_category() {   # $1 = topic → echoes the category slug
    case "$1" in
        ai)                   printf 'agent-clis' ;;
        languages|databases)  printf 'runtimes-dbs' ;;
        *)                    printf 'cli-tools' ;;
    esac
}
_update_enabled() {    # $1 = category → rc 0 if the user opted that category in
    case "$1" in
        agent-clis)    [[ "${MESH_UPDATE_AGENT_CLIS:-0}"   == 1 || "${MESH_UPDATE_AGENT_CLIS:-0}"   == true ]] ;;
        runtimes-dbs)  [[ "${MESH_UPDATE_RUNTIMES_DBS:-0}" == 1 || "${MESH_UPDATE_RUNTIMES_DBS:-0}" == true ]] ;;
        cli-tools)     [[ "${MESH_UPDATE_CLI_TOOLS:-0}"    == 1 || "${MESH_UPDATE_CLI_TOOLS:-0}"    == true ]] ;;
        *)             return 1 ;;
    esac
}

# Finish the legacy state-dir rename one-shot (audit T-004). Needed here too
# because auto-update invokes the engine directly, without sourcing setup.sh.
# Moves the whole pre-rename state dir (incl. secrets.env) into ~/.local/state/mesh.
mesh_migrate_legacy_state

# Resolve which secrets file to source: explicit override wins; otherwise the
# single canonical location (legacy read dropped post-migration, T-003/T-004).
SECRETS_FILES=()
if [[ -n "$SECRETS_OVERRIDE" ]]; then
    SECRETS_FILES=("$SECRETS_OVERRIDE")
elif [[ -r "$SECRETS_FILE_NEW" ]]; then
    SECRETS_FILES=("$SECRETS_FILE_NEW")
fi

# Per-topic parsed-manifest cache (one yaml-parse run per topic, reused across
# that topic's bundles). Cleaned on exit.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mesh-engine.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --repair bookkeeping: per-item subshells append to these so the parent can
# tally the sweep (subshells can't set parent vars). One "topic/bundle/name"
# per healthy/fixed line; "topic/bundle/name<TAB>reason" per unresolved item.
REPAIR_OK_FILE="$WORK/repair-ok"
REPAIR_FIXED_FILE="$WORK/repair-fixed"
REPAIR_FAIL_FILE="$WORK/repair-failures"

# --adopt bookkeeping: per-item subshells append one "topic/bundle/name" per
# marker written, so the parent can report how many pre-existing installs were
# adopted. Same subshell-can't-set-parent-vars rationale as the repair files.
ADOPT_DONE_FILE="$WORK/adopt-done"

# ─── selection collection ────────────────────────────────────────────────────

SEL_ENTRIES=()

_add_entry() {
    # Append "topic/bundle" if not already present. Rejects malformed entries.
    local e="$1"
    case "$e" in
        */*) : ;;
        *) log_error "malformed selection (need topic/bundle): $e"; exit 64 ;;
    esac
    local x
    for x in "${SEL_ENTRIES[@]+"${SEL_ENTRIES[@]}"}"; do
        [[ "$x" == "$e" ]] && return 0
    done
    SEL_ENTRIES+=("$e")
}

if [[ -n "$SELECTIONS_FILE" ]]; then
    [[ -r "$SELECTIONS_FILE" ]] || { log_error "unreadable --selections file: $SELECTIONS_FILE"; exit 64; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"                       # strip trailing comment
        line="${line#"${line%%[![:space:]]*}"}"  # ltrim
        line="${line%"${line##*[![:space:]]}"}"  # rtrim
        [[ -z "$line" ]] && continue
        _add_entry "$line"
    done < "$SELECTIONS_FILE"
fi
for b in "${CLI_BUNDLES[@]+"${CLI_BUNDLES[@]}"}"; do
    _add_entry "$b"
done

if [[ "${#SEL_ENTRIES[@]}" -eq 0 ]]; then
    log_error "no bundles selected (pass --selections FILE or --bundle topic/bundle)"
    exit 64
fi

# ─── manifest accessors (operate on the per-topic vars cache) ─────────────────

_ensure_topic_parsed() {
    local topic="$1"
    local vf="$WORK/topic__$topic.vars" mf="$TOPICS_DIR/$topic/manifest.yaml"
    [[ -f "$vf" ]] && return 0
    [[ -r "$mf" ]] || { log_error "no manifest for topic: $topic ($mf)"; return 1; }
    bash "$ENGINE_DIR/yaml-parse.sh" < "$mf" > "$vf" \
        || { log_error "yaml-parse failed for topic: $topic"; return 1; }
    grep -q '^__YAML_PARSE_OK=1$' "$vf" \
        || { log_error "yaml-parse sentinel missing for topic: $topic"; return 1; }
}

# Echo the 0-based bundle index whose name matches $2 within topic $1, or rc 1.
_bundle_index() {
    local topic="$1" want="$2"
    (
        # shellcheck disable=SC1090
        . "$WORK/topic__$topic.vars"
        local n="${BUNDLE_COUNT:-0}" i nv
        for ((i=0; i<n; i++)); do
            nv="BUNDLE_${i}_NAME"
            [[ "${!nv:-}" == "$want" ]] && { printf '%s' "$i"; exit 0; }
        done
        exit 1
    )
}

# Echo each requires_bundles entry of topic/idx, one "topic/bundle" per line.
_bundle_requires() {
    local topic="$1" idx="$2"
    (
        # shellcheck disable=SC1090
        . "$WORK/topic__$topic.vars"
        local cv="BUNDLE_${idx}_REQUIRES_BUNDLES_COUNT" c j ev
        c="${!cv:-0}"
        for ((j=0; j<c; j++)); do
            ev="BUNDLE_${idx}_REQUIRES_BUNDLES_${j}"
            printf '%s\n' "${!ev}"
        done
    )
}

# rc 0 if the bundle's platforms: list is empty or includes $PLATFORM.
_bundle_applies_platform() {
    local topic="$1" idx="$2"
    (
        # shellcheck disable=SC1090
        . "$WORK/topic__$topic.vars"
        local cv="BUNDLE_${idx}_PLATFORMS_COUNT" c j pv
        c="${!cv:-0}"
        [[ "$c" -gt 0 ]] || exit 0
        for ((j=0; j<c; j++)); do
            pv="BUNDLE_${idx}_PLATFORMS_${j}"
            [[ "${!pv:-}" == "$PLATFORM" ]] && exit 0
        done
        exit 1
    )
}

_in_list() {
    local needle="$1"; shift
    local x
    for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
    return 1
}

# ─── dependency closure (auto-select required bundles, spec §5.1) ─────────────
# BFS over requires_bundles. A selected bundle's deps are added to the working
# set even if not explicitly chosen; the menu surfaces this as an auto-select
# banner (T-308), but the engine enforces it regardless of how it was invoked.

queue=("${SEL_ENTRIES[@]}")
while [[ "${#queue[@]}" -gt 0 ]]; do
    entry="${queue[0]}"
    queue=("${queue[@]:1}")
    topic="${entry%%/*}"; bundle="${entry#*/}"
    _ensure_topic_parsed "$topic" || exit 65
    if ! idx="$(_bundle_index "$topic" "$bundle")"; then
        log_error "selected bundle does not exist: $entry"
        exit 64
    fi
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        if ! _in_list "$dep" "${SEL_ENTRIES[@]+"${SEL_ENTRIES[@]}"}"; then
            log_info "auto-selecting $dep (required by $entry)"
            _add_entry "$dep"
            queue+=("$dep")
        fi
    done < <(_bundle_requires "$topic" "$idx")
done

# ─── stable baseline order: (topic.order, bundle index) ───────────────────────
# Selections may arrive in any order (alpha glob, menu toggle order, hand-edited
# list). Establish a deterministic baseline so e.g. foundation (order 10) runs
# before later topics even when nothing declares requires_bundles: foundation.
# The topo-sort below still overrides this wherever requires_bundles demands it.

_topic_order() {
    (
        # shellcheck disable=SC1090
        . "$WORK/topic__$1.vars"
        printf '%s' "${TOPIC_ORDER:-9999}"
    )
}

_sorted=()
while IFS= read -r _e; do
    [[ -n "$_e" ]] && _sorted+=("$_e")
done < <(
    for entry in "${SEL_ENTRIES[@]}"; do
        topic="${entry%%/*}"; bundle="${entry#*/}"
        idx="$(_bundle_index "$topic" "$bundle")"
        printf '%06d:%03d\t%s\n' "$(_topic_order "$topic")" "$idx" "$entry"
    done | sort | cut -f2-
)
SEL_ENTRIES=("${_sorted[@]}")

# ─── topological sort (deps first, spec §5.1) ─────────────────────────────────
# Kahn-style: repeatedly emit any not-yet-emitted node whose every in-set
# dependency is already emitted. Preserves the baseline order among ready nodes.
# A pass with no progress means a cycle (validator forbids it; defensive here).

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
        if [[ "$deps_ok" -eq 1 ]]; then
            ORDERED+=("$entry"); progressed=1
        else
            leftover+=("$entry")
        fi
    done
    remaining=("${leftover[@]+"${leftover[@]}"}")
    if [[ "$progressed" -eq 0 ]]; then
        log_error "cycle in requires_bundles among: ${remaining[*]}"
        exit 70
    fi
done

# ─── per-bundle apply ─────────────────────────────────────────────────────────

apply_bundle() {
    # Runs in a subshell (caller wraps in (...)). Sources the topic's parsed
    # vars, exports resolved option env vars, then processes the bundle's items.
    local topic="$1" bundle="$2"
    local B; B="$(_bundle_index "$topic" "$bundle")"
    local TOPIC="$topic"

    cd "$TOPICS_DIR/$topic" || { log_error "$topic: cannot cd into topic dir"; exit 64; }

    # shellcheck disable=SC1090
    . "$WORK/topic__$topic.vars"

    # ── resolve + export option env vars ──
    # Source persisted values first (params.env = non-secret, secrets.env =
    # secret). `set -a` so every sourced KEY=value is exported to item scripts.
    set -a
    if [[ -r "$PARAMS_FILE" ]]; then
        # shellcheck disable=SC1090
        . "$PARAMS_FILE" || log_warn "$topic: could not source params file"
    fi
    local sf
    for sf in "${SECRETS_FILES[@]+"${SECRETS_FILES[@]}"}"; do
        # shellcheck disable=SC1090
        . "$sf" 2>/dev/null || log_warn "$topic: could not source secrets file ($sf)"
    done
    set +a

    local optc_var="BUNDLE_${B}_OPTION_COUNT" optc o
    optc="${!optc_var:-0}"
    for ((o=0; o<optc; o++)); do
        local oenv_var="BUNDLE_${B}_OPTION_${o}_ENV"
        local oenv="${!oenv_var:-}"
        [[ -n "$oenv" ]] || continue
        local otype_var="BUNDLE_${B}_OPTION_${o}_TYPE"
        local otype="${!otype_var:-}"
        local cur="${!oenv:-}"

        # Normalize an already-present toggle value to 1/0 so `when:` and item
        # scripts see a consistent boolean regardless of how it was written.
        if [[ "$otype" == "toggle" && -n "$cur" ]]; then
            case "$cur" in 1|true|yes|on|TRUE|True|Yes|On) export "$oenv=1" ;; *) export "$oenv=0" ;; esac
            continue
        fi
        [[ -n "$cur" ]] && continue          # already resolved (from params/secrets/env)
        [[ "$NON_INTERACTIVE" == "1" ]] || continue   # interactive: menu owns prompting

        # ── silent default for --non-interactive ──
        case "$otype" in
            toggle)
                local d_var="BUNDLE_${B}_OPTION_${o}_DEFAULT"
                local d="${!d_var:-false}"
                case "$d" in 1|true|yes|on|TRUE|True|Yes|On) export "$oenv=1" ;; *) export "$oenv=0" ;; esac
                ;;
            multiselect)
                local dc_var="BUNDLE_${B}_OPTION_${o}_DEFAULT_COUNT" dc k acc=""
                dc="${!dc_var:-0}"
                for ((k=0; k<dc; k++)); do
                    local dk_var="BUNDLE_${B}_OPTION_${o}_DEFAULT_${k}"
                    acc="${acc:+$acc }${!dk_var}"
                done
                [[ -n "$acc" ]] && export "$oenv=$acc"
                ;;
            text)
                local df_var="BUNDLE_${B}_OPTION_${o}_DEFAULT_FROM"
                local df="${!df_var:-}"
                local dv_var="BUNDLE_${B}_OPTION_${o}_DEFAULT"
                local dv="${!dv_var:-}"
                local val=""
                if [[ -n "$df" ]]; then
                    val="$(bash -c "$df" 2>/dev/null || true)"
                fi
                [[ -z "$val" && -n "$dv" ]] && val="$dv"
                [[ -n "$val" ]] && export "$oenv=$val"
                ;;
            select)
                local sdv_var="BUNDLE_${B}_OPTION_${o}_DEFAULT"
                local sdv="${!sdv_var:-}"
                [[ -n "$sdv" ]] && export "$oenv=$sdv"
                ;;
            secret) : ;;   # never auto-filled; absent = item handles it / skips
        esac
    done

    # Resolve `when: option.<name>` to the toggle's exported env value.
    # rc 0 = truthy (run), rc 1 = falsy/unknown (skip).
    _option_is_on() {
        local oname="$1" oc_var="BUNDLE_${B}_OPTION_COUNT" oc i
        oc="${!oc_var:-0}"
        for ((i=0; i<oc; i++)); do
            local nv="BUNDLE_${B}_OPTION_${i}_NAME"
            if [[ "${!nv:-}" == "$oname" ]]; then
                local ev="BUNDLE_${B}_OPTION_${i}_ENV"
                local e="${!ev:-}"; [[ -n "$e" ]] || return 1
                case "${!e:-}" in 1|true|yes|on|TRUE|True|Yes|On) return 0 ;; *) return 1 ;; esac
            fi
        done
        return 1
    }

    # ── item loop ──
    local icount_var="BUNDLE_${B}_ITEM_COUNT" icount i
    icount="${!icount_var:-0}"
    local bundle_processed=0
    for ((i=0; i<icount; i++)); do
        local p="BUNDLE_${B}_ITEM_${i}"
        local name="${p}_NAME";        name="${!name:-}"
        local type="${p}_TYPE";        type="${!type:-}"
        local spec="${p}_SPEC";        spec="${!spec:-}"
        local script="${p}_SCRIPT";    script="${!script:-}"
        local mcheck="${p}_CHECK";     mcheck="${!mcheck:-}"
        local when="${p}_WHEN";        when="${!when:-}"
        local idem="${p}_IDEMPOTENT";  idem="${!idem:-0}"
        [[ -n "$name" ]] || break
        [[ -n "$type" ]] || { log_error "$bundle/$name: item missing required 'type'"; exit 64; }

        # item-level platform gate
        local pc_var="${p}_PLATFORMS_COUNT" pc j ok_platform
        pc="${!pc_var:-0}"
        if [[ "$pc" -gt 0 ]]; then
            ok_platform=0
            for ((j=0; j<pc; j++)); do
                local pe_var="${p}_PLATFORMS_${j}"
                [[ "${!pe_var:-}" == "$PLATFORM" ]] && { ok_platform=1; break; }
            done
            if [[ "$ok_platform" -eq 0 ]]; then
                log_info "$bundle/$name: skip (platforms: excludes $PLATFORM)"
                continue
            fi
        fi

        # when: gate
        if [[ -n "$when" ]]; then
            case "$when" in
                option.*)
                    if ! _option_is_on "${when#option.}"; then
                        log_info "$bundle/$name: skip (when: $when is off)"
                        continue
                    fi
                    ;;
                *)
                    local _wrc=0
                    cond_eval "$when" || _wrc=$?
                    if [[ "$_wrc" -eq 2 ]]; then
                        log_error "$bundle/$name: when: references unknown condition '$when'"
                        exit 71
                    elif [[ "$_wrc" -ne 0 ]]; then
                        log_info "$bundle/$name: skip (when: $when is false)"
                        continue
                    fi
                    ;;
            esac
        fi

        # resolve dispatch arg
        local arg
        if [[ "$type" == "custom" ]]; then
            arg="$script"
            [[ -n "$arg" ]] || { log_error "$bundle/$name: type=custom missing 'script'"; exit 64; }
        else
            arg="$spec"
            # defense-in-depth: refuse leading-dash specs (would be parsed as a
            # CLI option by most package managers).
            if [[ "$arg" == -* ]]; then
                log_error "$bundle/$name: spec begins with '-' (refused for $type driver)"
                exit 64
            fi
        fi

        if [[ "$DRY_RUN" -eq 1 ]]; then
            local idem_note=""; [[ "$idem" == "1" ]] && idem_note=" idempotent"
            log_info "[dry-run] would process: $bundle/$name ($type$idem_note) arg=$arg"
            bundle_processed=$((bundle_processed+1))
            continue
        fi

        (   # per-item subshell isolation
            local driver="$INSTALLERS_DIR/${type}.sh"
            if [[ ! -r "$driver" ]]; then
                log_error "no driver for type=$type (item: $bundle/$name)"
                exit 66
            fi
            # shellcheck disable=SC1090
            . "$driver"
            local prefix="${type//-/_}"

            # adopt mode (scanner-marker-coherence handoff, Option A): a read-only
            # marker backfill. For each marker-ABSENT item whose STRONGEST probe
            # passes (driver verify > manifest check > driver check) write the
            # install marker WITHOUT install/deploy/sudo. This reconciles the
            # drift-in state a v1-migrated (or foreign) install leaves — tool
            # present but no v2 marker — so the marker-only menu scanner stops
            # reporting it `missing`. Inverse of --repair: same probe, but it
            # targets marker-ABSENT items and the marker is its ONLY write.
            # Idempotent items have no install-state (always-run, e.g. banners) →
            # nothing to adopt. An item that already has a marker → no-op. An item
            # that is absent/unprobeable gets NO marker. Always exits 0 (a tool
            # that simply isn't here is not an error), so the sweep is best-effort
            # and safe to re-run.
            if [[ "$ADOPT_MODE" -eq 1 ]]; then
                if [[ "$idem" == "1" ]]; then
                    log_info "$bundle/$name: adopt skip (idempotent — no install state to adopt)"; exit 0
                fi
                if [[ -f "$(install_state_path "$TOPIC" "$name")" ]]; then
                    log_info "$bundle/$name: adopt skip (already has a marker)"; exit 0
                fi
                _adopt_probe() {   # driver verify > manifest check > driver check
                    if declare -f "${prefix}_verify" >/dev/null 2>&1; then
                        "${prefix}_verify" "$arg"
                    elif [[ -n "$mcheck" ]]; then
                        bash -c "$mcheck" >/dev/null 2>&1
                    elif declare -f "${prefix}_check" >/dev/null 2>&1; then
                        "${prefix}_check" "$arg" 2>/dev/null
                    else
                        return 2   # no probe available → cannot confirm presence
                    fi
                }
                local _aprc=0
                _adopt_probe >/dev/null 2>&1 || _aprc=$?
                if [[ "$_aprc" -ne 0 ]]; then
                    log_info "$bundle/$name: adopt skip (not present / unprobeable)"; exit 0
                fi
                if install_state_record "$TOPIC" "$name" "$type" "$arg"; then
                    printf '%s\n' "$bundle/$name" >> "$ADOPT_DONE_FILE" 2>/dev/null || true
                    log_info "$bundle/$name: adopted ✓ (present, marker written)"
                else
                    log_warn "$bundle/$name: present but failed to write marker"
                fi
                exit 0
            fi

            # repair mode (verify/operational plan §C): verify each installed
            # item with its STRONGEST probe; on failure attempt ONE repair through
            # the installer, then re-probe. Failures are RECORDED (not aborting)
            # so one pass reports every broken item. Idempotent / no-probe items
            # are re-applied by `mesh update`, not here — skipped.
            if [[ "$REPAIR_MODE" -eq 1 ]]; then
                if [[ "$idem" == "1" ]]; then
                    log_info "$bundle/$name: repair skip (idempotent — re-applied by mesh update)"; exit 0
                fi
                _repair_probe() {   # driver verify > manifest check > driver check
                    if declare -f "${prefix}_verify" >/dev/null 2>&1; then
                        "${prefix}_verify" "$arg"
                    elif [[ -n "$mcheck" ]]; then
                        bash -c "$mcheck" >/dev/null 2>&1
                    elif declare -f "${prefix}_check" >/dev/null 2>&1; then
                        "${prefix}_check" "$arg" 2>/dev/null
                    else
                        return 2   # no probe available
                    fi
                }
                local _probe_rc=0
                _repair_probe || _probe_rc=$?
                if [[ "$_probe_rc" -eq 2 ]]; then
                    log_info "$bundle/$name: repair skip (no probe — re-applied by mesh update)"; exit 0
                fi
                if [[ "$_probe_rc" -eq 0 ]]; then
                    printf '%s\n' "$bundle/$name" >> "$REPAIR_OK_FILE" 2>/dev/null || true
                    log_info "$bundle/$name: ok"; exit 0
                fi
                # probe failed → only repair what mesh actually installed (marker
                # present). A no-marker probe-fail is "not installed here" → skip;
                # collision-safe because we iterate THIS bundle's items in context.
                if [[ ! -f "$(install_state_path "$TOPIC" "$name")" ]]; then
                    log_info "$bundle/$name: repair skip (probe fails, no install marker — not installed here)"; exit 0
                fi
                log_warn "$bundle/$name: BROKEN (strong probe failed) → attempting repair"
                local _rrc=0
                if declare -f "${prefix}_repair" >/dev/null 2>&1; then
                    "${prefix}_repair" "$arg" || _rrc=$?
                else
                    "${prefix}_install" "$arg" || _rrc=$?
                fi
                if [[ "$_rrc" -eq 75 ]]; then
                    printf '%s\t(no safe auto-repair — define repair())\n' "$bundle/$name" >> "$REPAIR_FAIL_FILE" 2>/dev/null || true
                    log_error "$bundle/$name: no safe auto-repair available — manual fix needed"; exit 0
                elif [[ "$_rrc" -ne 0 ]]; then
                    printf '%s\t(repair action failed rc=%s)\n' "$bundle/$name" "$_rrc" >> "$REPAIR_FAIL_FILE" 2>/dev/null || true
                    log_error "$bundle/$name: repair action failed (rc=$_rrc)"; exit 0
                fi
                local _reverc=0
                _repair_probe || _reverc=$?
                if [[ "$_reverc" -eq 0 ]]; then
                    install_state_record "$TOPIC" "$name" "$type" "$arg" 2>/dev/null || true
                    printf '%s\n' "$bundle/$name" >> "$REPAIR_FIXED_FILE" 2>/dev/null || true
                    log_info "$bundle/$name: repaired ✓"; exit 0
                fi
                printf '%s\t(still broken after repair)\n' "$bundle/$name" >> "$REPAIR_FAIL_FILE" 2>/dev/null || true
                log_error "$bundle/$name: still broken after repair — manual intervention required"; exit 0
            fi

            # update mode (T-600): upgrade an already-installed item via the
            # driver's version-aware <type>_update, gated by its opt-in category.
            # Never installs new items; skips items without an updater (e.g.
            # deploy/config) — those are re-applied by `mesh update`'s apply pass.
            if [[ "$UPDATE_MODE" -eq 1 ]]; then
                local _cat; _cat="$(_update_category "$TOPIC")"
                if ! _update_enabled "$_cat"; then
                    log_info "$bundle/$name: update skip (category '$_cat' off)"; exit 0
                fi
                if ! declare -f "${prefix}_update" >/dev/null 2>&1; then
                    log_info "$bundle/$name: update skip (no updater for type=$type)"; exit 0
                fi
                local _installed=0
                if [[ -n "$mcheck" ]]; then
                    bash -c "$mcheck" >/dev/null 2>&1 && _installed=1
                elif [[ "$idem" == "1" ]]; then
                    [[ -f "$(install_state_path "$TOPIC" "$name")" ]] && _installed=1
                elif "${prefix}_check" "$arg" 2>/dev/null; then
                    _installed=1
                fi
                if (( _installed == 0 )); then
                    log_info "$bundle/$name: update skip (not installed)"; exit 0
                fi
                log_info "$bundle/$name: checking for update [$_cat]"
                local _urc=0
                "${prefix}_update" "$arg" || _urc=$?
                if [[ "$_urc" -ne 0 ]]; then
                    log_warn "$bundle/$name: update failed (rc=$_urc)"; exit "$_urc"
                fi
                install_state_record "$TOPIC" "$name" "$type" "$arg" 2>/dev/null || true
                exit 0
            fi

            # idempotent items (spec §11): skip pre-check + post-verify, always run.
            if [[ "$idem" == "1" ]]; then
                log_info "$bundle/$name: running (idempotent)"
                local _rc=0
                "${prefix}_install" "$arg" || _rc=$?
                if [[ "$_rc" -ne 0 ]]; then
                    log_warn "$bundle/$name: install failed (rc=$_rc); rollback if present"
                    declare -f "${prefix}_rollback" >/dev/null 2>&1 && "${prefix}_rollback" "$arg"
                    exit "$_rc"
                fi
                install_state_record "$TOPIC" "$name" "$type" "$arg" \
                    || log_warn "$bundle/$name: failed to record install marker (continuing)"
                exit 0
            fi

            # pre-install check: manifest `check:` overrides driver _check.
            if [[ -n "$mcheck" ]]; then
                if bash -c "$mcheck" >/dev/null 2>&1; then
                    install_state_record "$TOPIC" "$name" "$type" "$arg" 2>/dev/null || true
                    log_info "$bundle/$name: already present (manifest check), skipping"
                    exit 0
                fi
            elif "${prefix}_check" "$arg" 2>/dev/null; then
                install_state_record "$TOPIC" "$name" "$type" "$arg" 2>/dev/null || true
                log_info "$bundle/$name: already present, skipping"
                exit 0
            fi

            log_info "$bundle/$name: installing"
            local _install_rc=0
            "${prefix}_install" "$arg" || _install_rc=$?
            if [[ "$_install_rc" -ne 0 ]]; then
                log_warn "$bundle/$name: install failed (rc=$_install_rc); rollback if present"
                declare -f "${prefix}_rollback" >/dev/null 2>&1 && "${prefix}_rollback" "$arg"
                exit "$_install_rc"
            fi

            # post-install verify: driver verify > manifest check > driver check.
            local _post_ok=0
            if declare -f "${prefix}_verify" >/dev/null 2>&1; then
                "${prefix}_verify" "$arg" && _post_ok=1
            elif [[ -n "$mcheck" ]]; then
                bash -c "$mcheck" >/dev/null 2>&1 && _post_ok=1
            else
                "${prefix}_check" "$arg" 2>/dev/null && _post_ok=1
            fi
            if (( _post_ok == 0 )); then
                log_warn "$bundle/$name: post-install verification failed; rollback if present"
                declare -f "${prefix}_rollback" >/dev/null 2>&1 && "${prefix}_rollback" "$arg"
                exit 67
            fi

            install_state_record "$TOPIC" "$name" "$type" "$arg" \
                || log_warn "$bundle/$name: failed to record install marker (continuing)"

            # optional post: hooks (scalar or list, expanded by yaml-parse).
            local post_count_var="${p}_POST_COUNT" post_count
            post_count="${!post_count_var:-0}"
            if (( post_count > 0 )); then
                local pidx
                for ((pidx=0; pidx<post_count; pidx++)); do
                    local pe_var="${p}_POST_${pidx}"
                    local post_cmd="${!pe_var:-}"
                    [[ -n "$post_cmd" ]] || continue
                    if ! bash -c "$post_cmd"; then
                        log_warn "$bundle/$name: post[$pidx] failed; rollback if present"
                        declare -f "${prefix}_rollback" >/dev/null 2>&1 && "${prefix}_rollback" "$arg"
                        exit 69
                    fi
                done
                log_info "$bundle/$name: post completed ($post_count command(s))"
            fi
        ) || { local _rc=$?; log_error "$bundle/$name: failed (rc=$_rc)"; exit $_rc; }
        bundle_processed=$((bundle_processed+1))
    done

    log_info "$topic/$bundle: completed ($bundle_processed item(s) on $PLATFORM)"
}

# ─── drive the ordered bundle list ────────────────────────────────────────────

bundles_done=0
bundles_skipped=0
for entry in "${ORDERED[@]}"; do
    topic="${entry%%/*}"; bundle="${entry#*/}"
    idx="$(_bundle_index "$topic" "$bundle")"
    if ! _bundle_applies_platform "$topic" "$idx"; then
        log_info "$entry: skip bundle (platforms: excludes $PLATFORM)"
        bundles_skipped=$((bundles_skipped+1))
        continue
    fi
    ( apply_bundle "$topic" "$bundle" ) || { _rc=$?; log_error "$entry: bundle failed (rc=$_rc)"; exit $_rc; }
    bundles_done=$((bundles_done+1))
done

# ─── repair-mode summary (verify/operational plan §C) ─────────────────────────
# In repair mode item subshells exit 0 and record their outcome to files; tally
# them here. rc 67 if any item is left unresolved, rc 0 on a healthy/fixed tree.
if [[ "$REPAIR_MODE" -eq 1 ]]; then
    _r_ok=0; _r_fixed=0; _r_fail=0
    [[ -s "$REPAIR_OK_FILE" ]]    && _r_ok="$(grep -c . "$REPAIR_OK_FILE")"
    [[ -s "$REPAIR_FIXED_FILE" ]] && _r_fixed="$(grep -c . "$REPAIR_FIXED_FILE")"
    [[ -s "$REPAIR_FAIL_FILE" ]]  && _r_fail="$(grep -c . "$REPAIR_FAIL_FILE")"
    log_info "repair sweep on $PLATFORM: $_r_ok healthy, $_r_fixed repaired, $_r_fail unresolved"
    if (( _r_fail > 0 )); then
        log_error "repair: $_r_fail item(s) could not be repaired:"
        while IFS= read -r _l; do [[ -n "$_l" ]] && log_error "  - $_l"; done < "$REPAIR_FAIL_FILE"
        exit 67
    fi
    exit 0
fi

# ─── adopt-mode summary (scanner-marker-coherence handoff) ────────────────────
# Read-only sweep: item subshells exit 0 and append to ADOPT_DONE_FILE per marker
# written. Tally + report; adopt is best-effort so it always exits 0.
if [[ "$ADOPT_MODE" -eq 1 ]]; then
    _a_done=0
    [[ -s "$ADOPT_DONE_FILE" ]] && _a_done="$(grep -c . "$ADOPT_DONE_FILE")"
    log_info "adopt sweep on $PLATFORM: $_a_done marker(s) written for pre-existing installs"
    exit 0
fi

if (( bundles_skipped > 0 )); then
    log_info "engine: applied $bundles_done bundle(s) on $PLATFORM ($bundles_skipped skipped by platforms:)"
else
    log_info "engine: applied $bundles_done bundle(s) on $PLATFORM"
fi
