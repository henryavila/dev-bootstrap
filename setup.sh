#!/usr/bin/env bash
# setup.sh — configure this machine: pick bundles, then apply them via the engine.
#
# Manifest v2 flow (F9.6): the unit of selection is the BUNDLE (topic/bundle).
#   interactive (default on a TTY): run the blink-tui menu (scripts/menu), which
#     writes ~/.config/mesh/{selections.list,params.env}; then the engine applies
#     the selection. If the menu is not built yet, fall back to default selections.
#   --non-interactive / NON_INTERACTIVE=1: skip the menu. Honor an existing
#     selections.list if present; otherwise compute the default selection
#     (every bundle except those with default_selected:false) and let the engine
#     resolve silent option defaults.
#
# State (spec §4.6, ratified D-15):
#   ~/.config/mesh/{selections.list,params.env}  — menu/user state
#   ~/.local/state/mesh/{installed/,secrets.env}  — machine/install state
#
# Env vars (primarily for automation/CI):
#   NON_INTERACTIVE=1     skip the menu even on a TTY
#   DRY_RUN=1             print what the engine would do without executing
#   MESH_IDENTITY_REPO    identity repo URL (used by ai / personal topics)
#   MESH_IDENTITY_DIR     where to clone the identity repo (default ~/mesh-identity)
#   CODE_DIR              dev root — where your repos live (default ~/code). Asked
#                         in the menu (dev-root screen); persisted to config.env.
#   NO_COLOR=1            disable colored output (auto if not a TTY)
#
# Usage: bash setup.sh [--help] [--non-interactive] [--dry-run] [--list-bundles]
set -euo pipefail

# Minimal shells (docker run, `su -`, env -i) leave $USER unset even with a real
# uid. `id -un` always works. Exported so every item script sees a consistent value.
export USER="${USER:-$(id -un)}"
export HOME="${HOME:-$(getent passwd "$USER" | cut -d: -f6)}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# ─── arg parsing (introspection flags exit before any side effects) ──────────
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
DRY_RUN="${DRY_RUN:-0}"
LIST_BUNDLES=0
REPAIR_MODE=0
ADOPT_MODE=0
for arg in "$@"; do
    case "$arg" in
        --help|-h)        SHOW_HELP=1 ;;
        --non-interactive) NON_INTERACTIVE=1 ;;
        --dry-run)        DRY_RUN=1 ;;
        --list-bundles)   LIST_BUNDLES=1 ;;
        --repair)         REPAIR_MODE=1 ;;
        --adopt)          ADOPT_MODE=1 ;;
        *) echo "setup.sh: unknown arg: $arg (try --help)" >&2; exit 64 ;;
    esac
done
# --repair (verify/operational plan §C, via `mesh doctor --fix`): a verify+repair
# sweep, never the menu. Force non-interactive so the menu is skipped and any
# unset option falls back to its silent default; the engine repairs only items
# with an install marker (so the selection just scopes the sweep).
[[ "$REPAIR_MODE" == "1" ]] && NON_INTERACTIVE=1
# --adopt (scanner-marker-coherence handoff, via `mesh adopt`): a READ-ONLY
# marker backfill, never the menu. Force non-interactive (skip menu + silent
# option defaults); the engine writes a marker for every already-present item
# that lacks one — no install/deploy/sudo. Scopes over ALL bundles (below) so
# opt-in tools installed under v1 also get a marker.
[[ "$ADOPT_MODE" == "1" ]] && NON_INTERACTIVE=1
if [[ "$ADOPT_MODE" == "1" && "$REPAIR_MODE" == "1" ]]; then
    echo "setup.sh: --adopt and --repair are mutually exclusive" >&2; exit 64
fi
export NON_INTERACTIVE DRY_RUN

# shellcheck disable=SC1091
source "$HERE/scripts/lib/log.sh"

usage() {
    cat <<'EOF'
mesh-workstation — set up a development machine

Interactive mode (default on a TTY):
  bash setup.sh                  pick bundles in the menu, then apply

Automation / CI mode:
  NON_INTERACTIVE=1 bash setup.sh   skip the menu (use saved or default selection)
  bash setup.sh --non-interactive   same, flag form
  DRY_RUN=1 bash setup.sh           print what the engine would do, don't execute
  bash setup.sh --dry-run           same, flag form
  bash setup.sh --list-bundles      list every topic/bundle + default selection
  bash setup.sh --repair            verify+repair installed-but-broken items only
                                    (no menu; engine --repair; = mesh doctor --fix)
  bash setup.sh --adopt             read-only: backfill install markers for tools
                                    already present but unmarked (v1→v2 machines);
                                    no install/deploy/sudo (= mesh adopt)

Selection lives in ~/.config/mesh/selections.list (one topic/bundle per line);
resolved non-secret options in ~/.config/mesh/params.env. Delete selections.list
to reset to defaults. See topics/*/README.md for per-topic docs.
EOF
}

if [[ "${SHOW_HELP:-0}" == "1" ]]; then usage; exit 0; fi

# ─── enumerate manifests + default selection ─────────────────────────────────
# Default selection = every bundle whose default_selected is not false (required
# bundles are always in; parser omits the field when absent, so we apply the
# spec defaults required=0 / default_selected=1 via ${VAR:-default}).
emit_default_selections() {
    local mf topic vf
    for mf in "$HERE"/topics/*/manifest.yaml; do
        [[ -f "$mf" ]] || continue
        topic="$(basename "$(dirname "$mf")")"
        vf="$(bash "$HERE/scripts/lib/yaml-parse.sh" < "$mf" 2>/dev/null)" || continue
        (
            eval "$vf"
            [[ "${__YAML_PARSE_OK:-0}" == "1" ]] || exit 0
            local n="${BUNDLE_COUNT:-0}" i name_v ds_v req_v name ds req
            for ((i=0; i<n; i++)); do
                name_v="BUNDLE_${i}_NAME"; ds_v="BUNDLE_${i}_DEFAULT_SELECTED"; req_v="BUNDLE_${i}_REQUIRED"
                name="${!name_v:-}"; ds="${!ds_v:-1}"; req="${!req_v:-0}"
                [[ -n "$name" ]] || continue
                if [[ "$req" == "1" || "$ds" != "0" ]]; then
                    printf '%s/%s\n' "$topic" "$name"
                fi
            done
        )
    done
}

# Every bundle, ignoring required / default_selected. Used by --adopt so the
# read-only marker backfill probes opt-in bundles too (a v1 machine may have
# installed Docker/MSSQL/etc.); the menu can then show true state for all of them.
emit_all_selections() {
    local mf topic vf
    for mf in "$HERE"/topics/*/manifest.yaml; do
        [[ -f "$mf" ]] || continue
        topic="$(basename "$(dirname "$mf")")"
        vf="$(bash "$HERE/scripts/lib/yaml-parse.sh" < "$mf" 2>/dev/null)" || continue
        (
            eval "$vf"
            [[ "${__YAML_PARSE_OK:-0}" == "1" ]] || exit 0
            local n="${BUNDLE_COUNT:-0}" i name_v name
            for ((i=0; i<n; i++)); do
                name_v="BUNDLE_${i}_NAME"; name="${!name_v:-}"
                [[ -n "$name" ]] || continue
                printf '%s/%s\n' "$topic" "$name"
            done
        )
    done
}

if [[ "$LIST_BUNDLES" == "1" ]]; then
    # topic/bundle  [default|opt-out]
    for mf in "$HERE"/topics/*/manifest.yaml; do
        [[ -f "$mf" ]] || continue
        topic="$(basename "$(dirname "$mf")")"
        vf="$(bash "$HERE/scripts/lib/yaml-parse.sh" < "$mf" 2>/dev/null)" || continue
        (
            eval "$vf"
            [[ "${__YAML_PARSE_OK:-0}" == "1" ]] || exit 0
            n="${BUNDLE_COUNT:-0}"
            for ((i=0; i<n; i++)); do
                name_v="BUNDLE_${i}_NAME"; ds_v="BUNDLE_${i}_DEFAULT_SELECTED"; req_v="BUNDLE_${i}_REQUIRED"
                name="${!name_v:-}"; ds="${!ds_v:-1}"; req="${!req_v:-0}"
                [[ -n "$name" ]] || continue
                if [[ "$req" == "1" ]]; then mark="required"
                elif [[ "$ds" == "0" ]]; then mark="opt-in (default off)"
                else mark="default on"; fi
                printf '%-32s %s\n' "$topic/$name" "$mark"
            done
        )
    done
    exit 0
fi

# ─── persistent state + secrets (sourced before the engine) ──────────────────
# Canonical state dir is ~/.local/state/mesh; finish the dev-bootstrap →
# mesh-workstation → mesh rename one-shot before anything reads state (T-004).
# shellcheck disable=SC1091
source "$HERE/scripts/lib/state-dir.sh"
[[ "$DRY_RUN" != "1" ]] && mesh_migrate_legacy_state
MESH_STATE_DIR="$(mesh_state_dir)"; export MESH_STATE_DIR
[[ "$DRY_RUN" != "1" ]] && mkdir -p "$MESH_STATE_DIR"

# Secrets (input-only tokens). Sourced so item scripts read them via env; the
# engine also sources them per bundle. See lib/secrets.sh for the key taxonomy.
# MESH_STATE_DIR is already the canonical mesh dir, so secrets.sh resolves
# MESH_SECRETS_FILE there (the legacy override removed — fixed T-004 F2).
# shellcheck disable=SC1091
source "$HERE/scripts/lib/secrets.sh"
secrets_load || warn "secrets file present but could not be sourced — continuing without it"

# Persisted decisions (e.g. a previously chosen BREW_PREFIX). See lib/state.sh.
# shellcheck disable=SC1091
source "$HERE/scripts/lib/state.sh"
state_load

# Defaults inherited by item scripts that read non-option env directly.
export MESH_IDENTITY_REPO="${MESH_IDENTITY_REPO:-}"
export MESH_IDENTITY_DIR="${MESH_IDENTITY_DIR:-$HOME/mesh-identity}"
export CODE_DIR="${CODE_DIR:-$HOME/code}"
export NO_COLOR="${NO_COLOR:-}"

# ─── mesh symlink (~/.local/bin/mesh → bin/mesh) ─────────────────────────────
install_mesh_symlink() {
    local dst="$HOME/.local/bin/mesh" target="$HERE/bin/mesh"
    if [[ -e "$HOME/.local/bin" && ! -d "$HOME/.local/bin" ]]; then
        warn "$HOME/.local/bin is not a directory — skipping mesh symlink install"; return 0
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "+ ln -sf $target $dst  [dry-run, skipped]"; return 0
    fi
    mkdir -p "$HOME/.local/bin"
    if [[ -L "$dst" && "$(readlink "$dst")" == "$target" ]]; then return 0; fi
    # A machine provisioned by the v1 system has a REGULAR FILE here (the
    # pre-rename `scripts/mesh` dispatcher, no doctor/adopt). Take ownership:
    # back it up (the deploy driver's .bak-<TS> pattern) and install the shim,
    # so v1-migrated boxes self-heal instead of keeping the stale dispatcher.
    if [[ -e "$dst" && ! -L "$dst" ]]; then
        local backup="$dst.bak-$(date +%Y%m%d-%H%M%S)"
        if ! mv "$dst" "$backup"; then
            warn "$dst is a regular file and could not be backed up — leaving alone"; return 0
        fi
        warn "$dst was a regular file (pre-v2 dispatcher) — backed up to $backup; installing the bin/mesh symlink"
    fi
    ln -sf "$target" "$dst"
}
install_mesh_symlink

# ─── detect OS + brew ────────────────────────────────────────────────────────
OS="$(bash "$HERE/scripts/lib/detect-os.sh")"
export OS MESH_OS="$OS"
[[ "$OS" == "unknown" ]] && { fail "unsupported OS (uname -s = $(uname -s))"; exit 1; }

banner "mesh-workstation :: $OS"

BREW_BIN=""; BREW_PREFIX=""
detect_brew_if_mac() {
    [[ "$OS" == "mac" ]] || return 0
    if out=$(bash "$HERE/scripts/lib/detect-brew.sh" 2>/dev/null); then
        eval "$out"; export BREW_BIN BREW_PREFIX
    fi
}
detect_brew_if_mac
if [[ "$OS" == "mac" ]]; then
    if [[ -n "$BREW_BIN" ]]; then info "brew found at $BREW_BIN (prefix $BREW_PREFIX)"
    else warn "brew not installed yet; the foundation topic will install it"; fi
fi

# ─── sudo warmup + legacy NOPASSWD cleanup ───────────────────────────────────
# Skipped under --adopt: a read-only marker backfill must never warm sudo or
# mutate sudoers (its probes are check()/verify() only — no privileged action).
if [[ "$DRY_RUN" != "1" && "$ADOPT_MODE" != "1" ]]; then
    sudo -v 2>/dev/null || warn "sudo cache warmup failed (non-fatal — items will prompt individually)"
fi
# Pre-v2026-04-22 remote-access left a permanent NOPASSWD sudoers entry.
# Clean it up unconditionally so forks inherit the fix.
if [[ ( "$OS" == "wsl" || "$OS" == "linux" ) && "$DRY_RUN" != "1" && "$ADOPT_MODE" != "1" ]]; then
    legacy_nopasswd="/etc/sudoers.d/10-${USER}-nopasswd"
    if [[ -f "$legacy_nopasswd" ]] || sudo test -f "$legacy_nopasswd" 2>/dev/null; then
        info "removing legacy NOPASSWD sudoers entry at $legacy_nopasswd"
        sudo rm -f "$legacy_nopasswd" && ok "legacy NOPASSWD sudoers removed"
    fi
fi

# Consolidated follow-up summary file (item scripts append via `followup`).
MESH_FOLLOWUP_FILE="$(mktemp -t mesh-workstation-followup.XXXXXX 2>/dev/null || mktemp)"
export MESH_FOLLOWUP_FILE
trap 'rm -f "${MESH_FOLLOWUP_FILE:-}"' EXIT

# ─── resolve the selection ───────────────────────────────────────────────────
SELECTIONS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mesh"
SELECTIONS_FILE="$SELECTIONS_DIR/selections.list"
# Bundles the menu computed as deselected-since-last-apply (computeDelta.remove).
# The menu writes them here; the Apply runs uninstall-engine on them BEFORE the
# install pass, then deletes the file. Headless runs have no menu/delta → no
# file → install-only (marker-diff for headless is future work, see handoff).
REMOVALS_FILE="$SELECTIONS_DIR/removals.list"
MENU_DIR="$HERE/scripts/menu"

run_menu_if_available() {
    # Propagates the menu's exit status so the caller can tell apart:
    #   0   = applied (wrote selections.list)         → use the selection
    #   130 = user quit / Ctrl-C (EXIT_CANCEL)         → abort the whole run
    #   2   = menu not present / Node missing          → fall back to default
    #   *   = no TTY (app.tsx) / crashed               → fall back to default
    [[ -f "$MENU_DIR/index.js" || -f "$MENU_DIR/dist/index.js" ]] || return 2
    command -v node >/dev/null 2>&1 || { warn "Node.js not found — cannot run the setup menu"; return 2; }
    info "launching the bundle menu…"
    # Gate on the key dep, not just node_modules/: a machine whose earlier run
    # left a PARTIAL node_modules (the old file:-link install that failed on a
    # host without the blink-tui checkout) would otherwise never reinstall.
    if [[ ! -d "$MENU_DIR/node_modules/@henryavila/blink-tui" ]]; then
        # blink-tui is a published npm package (peer-depends on react/ink, so a
        # single React instance dedupes naturally — no --install-links needed).
        (cd "$MENU_DIR" && npm install --omit=dev --no-audit --no-fund --silent 2>/dev/null) || true
    fi
    # Guard: if the install couldn't land the deps (no network / blocked
    # registry), fall back cleanly instead of letting `node` dump a raw
    # ERR_MODULE_NOT_FOUND stack trace at the user.
    if [[ ! -d "$MENU_DIR/node_modules/@henryavila/blink-tui" ]]; then
        warn "menu dependencies unavailable (could not install @henryavila/blink-tui) — skipping the menu"
        return 2
    fi
    node "$MENU_DIR/index.js"
}

should_run_menu() {
    [[ "$NON_INTERACTIVE" == "1" || "$DRY_RUN" == "1" ]] && return 1
    [[ -t 0 && -t 1 ]] || return 1
    return 0
}

if should_run_menu; then
    run_menu_if_available; menu_rc=$?
    if [[ "$menu_rc" -eq 130 ]]; then
        # The user explicitly quit the menu (q / Ctrl-C). Honour it: apply
        # nothing, do NOT silently fall back to the default selection.
        info "menu cancelled — nothing was applied."
        exit 130
    elif [[ "$menu_rc" -ne 0 ]]; then
        # Menu not built / Node missing / no TTY / crashed — fall back to the
        # saved or default selection (e.g. an automation/bootstrap run).
        warn "interactive bundle menu unavailable — falling back to the saved/default selection"
        NON_INTERACTIVE=1; export NON_INTERACTIVE
    fi
    # menu_rc == 0 → selections.list was written; proceed with it.
fi

# ─── persist the dev root (CODE_DIR) for the interactive shell ────────────────
# The menu writes CODE_DIR to params.env (the engine sources it, so the web stack
# gets the right site root at install time). But the interactive shell reads
# ~/.config/mesh/config.env, NOT params.env — mesh-identity's shell/aliases.sh
# sources config.env for auto-cd + the tmux project shortcuts. Bridge the two:
# lift CODE_DIR from params.env into config.env (idempotent line upsert that
# leaves every other line — repo paths, the AUTO_UPDATE_REPOS array — untouched),
# and re-export it so the post-menu engine pass inherits the chosen value.
persist_code_dir() {
    [[ "$DRY_RUN" == "1" ]] && return 0
    local params="$SELECTIONS_DIR/params.env" config="$SELECTIONS_DIR/config.env"
    [[ -f "$params" ]] || return 0
    # Source in a subshell so bash applies the same quoting it wrote — never
    # leaks the other KEY=values into setup.sh's environment.
    local chosen
    chosen="$(set +u; . "$params" >/dev/null 2>&1; printf '%s' "${CODE_DIR:-}")"
    [[ -n "$chosen" ]] || return 0
    export CODE_DIR="$chosen"
    mkdir -p "$SELECTIONS_DIR"
    local tmp; tmp="$(mktemp "$SELECTIONS_DIR/.config.env.XXXXXX")" || return 0
    {
        [[ -f "$config" ]] && grep -v '^CODE_DIR=' "$config"
        printf 'CODE_DIR=%q\n' "$chosen"
    } > "$tmp" && mv "$tmp" "$config" || { rm -f "$tmp"; return 0; }
    info "dev root persisted: CODE_DIR=$chosen → ${config/#$HOME/\~}"
}
persist_code_dir

if [[ "$ADOPT_MODE" == "1" ]]; then
    # Adopt probes EVERY bundle (not just the default/saved selection) so an
    # opt-in tool installed under v1 also gets its marker. Never persist a
    # selections.list as a side effect; feed the engine via a temp file. The
    # user's real selections.list (if any) is left untouched.
    SELECTIONS_FILE="$(mktemp -t mesh-adopt.XXXXXX)"
    trap 'rm -f "${MESH_FOLLOWUP_FILE:-}" "'"$SELECTIONS_FILE"'"' EXIT
    {
        echo "# mesh adopt — all bundles (read-only marker-backfill scope)"
        emit_all_selections
    } > "$SELECTIONS_FILE"
elif [[ ! -f "$SELECTIONS_FILE" ]]; then
    info "no selections.list — computing the default selection"
    mkdir -p "$SELECTIONS_DIR"
    if [[ "$DRY_RUN" == "1" || "$REPAIR_MODE" == "1" ]]; then
        # Don't persist a selections.list as a side effect of --dry-run or a
        # --repair sweep; feed the engine via a temp file (repair only touches
        # marker-present items anyway, so the default set merely scopes it).
        SELECTIONS_FILE="$(mktemp -t mesh-selections.XXXXXX)"
        trap 'rm -f "${MESH_FOLLOWUP_FILE:-}" "'"$SELECTIONS_FILE"'"' EXIT
    fi
    {
        echo "# mesh selections — auto-generated default (every bundle except default_selected:false)"
        emit_default_selections
    } > "$SELECTIONS_FILE"
fi

info "selections: $SELECTIONS_FILE"

# ─── apply via the engine ────────────────────────────────────────────────────
LOG="/tmp/mesh-workstation-$OS-$(date +%Y%m%d-%H%M%S).log"
info "full log: $LOG"

engine_args=(--selections "$SELECTIONS_FILE" --platform "$OS")
[[ "$NON_INTERACTIVE" == "1" ]] && engine_args+=(--non-interactive)
[[ "$DRY_RUN" == "1" ]] && engine_args+=(--dry-run)
[[ "$REPAIR_MODE" == "1" ]] && engine_args+=(--repair)
[[ "$ADOPT_MODE" == "1" ]] && engine_args+=(--adopt)

# ─── uninstall pass: bundles deselected in the menu (Frente A) ────────────────
# Run BEFORE install so re-selecting a previously-removed dependency reinstalls
# cleanly. Skipped under --repair (a marker sweep, independent of the selection)
# and when nothing was deselected. uninstall-engine takes no --non-interactive
# (it never prompts) and computes no requires_bundles closure, so it removes
# exactly the listed bundles — never an auto-removed shared dependency.
if [[ "$REPAIR_MODE" != "1" && "$ADOPT_MODE" != "1" ]] && [[ -s "$REMOVALS_FILE" ]] && grep -qvE '^[[:space:]]*(#|$)' "$REMOVALS_FILE"; then
    info "uninstall pass: $REMOVALS_FILE"
    uninstall_args=(--selections "$REMOVALS_FILE" --platform "$OS")
    [[ "$DRY_RUN" == "1" ]] && uninstall_args+=(--dry-run)
    set +e
    bash "$HERE/scripts/lib/uninstall-engine.sh" "${uninstall_args[@]}" 2>&1 | tee -a "$LOG"
    uninstall_rc="${PIPESTATUS[0]}"
    set -e
    [[ "$uninstall_rc" -ne 0 ]] && warn "uninstall pass exited rc=$uninstall_rc — continuing to install (see $LOG)"
    # Clear so a later plain re-run doesn't re-trigger the uninstall.
    [[ "$DRY_RUN" == "1" ]] || rm -f "$REMOVALS_FILE"
fi

set +e
bash "$HERE/scripts/lib/install-engine.sh" "${engine_args[@]}" 2>&1 | tee -a "$LOG"
engine_rc="${PIPESTATUS[0]}"
set -e

banner "summary"
render_followup_summary

if [[ "$engine_rc" -ne 0 ]]; then
    fail "engine exited with rc=$engine_rc — see $LOG"
    exit "$engine_rc"
fi

if ! command -v mesh >/dev/null 2>&1; then
    warn "mesh is installed at ~/.local/bin/mesh but not in your current \$PATH"
    warn "open a new terminal, or run:  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

ok "done — full log: $LOG"
