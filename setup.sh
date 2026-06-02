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
#   MESH_IDENTITY_REPO    identity repo URL (used by ai / dotfiles-personal)
#   MESH_IDENTITY_DIR     where to clone the identity repo (default ~/mesh-identity)
#   CODE_DIR              project root (default ~/code/web)
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
for arg in "$@"; do
    case "$arg" in
        --help|-h)        SHOW_HELP=1 ;;
        --non-interactive) NON_INTERACTIVE=1 ;;
        --dry-run)        DRY_RUN=1 ;;
        --list-bundles)   LIST_BUNDLES=1 ;;
        *) echo "setup.sh: unknown arg: $arg (try --help)" >&2; exit 64 ;;
    esac
done
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
BOOTSTRAP_STATE_DIR="$(mesh_state_dir)"; export BOOTSTRAP_STATE_DIR
[[ "$DRY_RUN" != "1" ]] && mkdir -p "$BOOTSTRAP_STATE_DIR"

# Secrets (input-only tokens). Sourced so item scripts read them via env; the
# engine also sources them per bundle. See lib/secrets.sh for the key taxonomy.
# BOOTSTRAP_STATE_DIR is already the canonical mesh dir, so secrets.sh resolves
# BOOTSTRAP_SECRETS_FILE there (the legacy override removed — fixed T-004 F2).
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
export CODE_DIR="${CODE_DIR:-$HOME/code/web}"
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
    if [[ -e "$dst" && ! -L "$dst" ]]; then
        warn "$dst is a regular file (not a symlink) — leaving alone; mv it aside to install the bin/mesh shim"; return 0
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
if [[ "$DRY_RUN" != "1" ]]; then
    sudo -v 2>/dev/null || warn "sudo cache warmup failed (non-fatal — items will prompt individually)"
fi
# Pre-v2026-04-22 70-remote-access left a permanent NOPASSWD sudoers entry.
# Clean it up unconditionally so forks inherit the fix.
if [[ ( "$OS" == "wsl" || "$OS" == "linux" ) && "$DRY_RUN" != "1" ]]; then
    legacy_nopasswd="/etc/sudoers.d/10-${USER}-nopasswd"
    if [[ -f "$legacy_nopasswd" ]] || sudo test -f "$legacy_nopasswd" 2>/dev/null; then
        info "removing legacy NOPASSWD sudoers entry at $legacy_nopasswd"
        sudo rm -f "$legacy_nopasswd" && ok "legacy NOPASSWD sudoers removed"
    fi
fi

# Consolidated follow-up summary file (item scripts append via `followup`).
BOOTSTRAP_FOLLOWUP_FILE="$(mktemp -t mesh-workstation-followup.XXXXXX 2>/dev/null || mktemp)"
export BOOTSTRAP_FOLLOWUP_FILE
trap 'rm -f "${BOOTSTRAP_FOLLOWUP_FILE:-}"' EXIT

# ─── resolve the selection ───────────────────────────────────────────────────
SELECTIONS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mesh"
SELECTIONS_FILE="$SELECTIONS_DIR/selections.list"
MENU_DIR="$HERE/scripts/menu"

run_menu_if_available() {
    # Returns 0 if the blink-tui menu ran and produced a selections file.
    [[ -f "$MENU_DIR/index.js" || -f "$MENU_DIR/dist/index.js" ]] || return 1
    command -v node >/dev/null 2>&1 || { warn "Node.js not found — cannot run the setup menu"; return 1; }
    info "launching the bundle menu…"
    if [[ ! -d "$MENU_DIR/node_modules" ]]; then
        # --install-links: pack the file: blink-tui dep as a real copy (dist only,
        # no bundled React) so React dedupes to one instance (else: invalid-hook).
        (cd "$MENU_DIR" && npm install --omit=dev --install-links --no-audit --no-fund --silent 2>/dev/null) || true
    fi
    node "$MENU_DIR/index.js" || return 1
    [[ -f "$SELECTIONS_FILE" ]]
}

should_run_menu() {
    [[ "$NON_INTERACTIVE" == "1" || "$DRY_RUN" == "1" ]] && return 1
    [[ -t 0 && -t 1 ]] || return 1
    return 0
}

if should_run_menu; then
    if ! run_menu_if_available; then
        # The Ink menu (F9.6 T-300+) is not built yet, or it was cancelled.
        warn "interactive bundle menu unavailable — falling back to the saved/default selection"
        NON_INTERACTIVE=1; export NON_INTERACTIVE
    fi
fi

if [[ ! -f "$SELECTIONS_FILE" ]]; then
    info "no selections.list — computing the default selection"
    mkdir -p "$SELECTIONS_DIR"
    if [[ "$DRY_RUN" == "1" ]]; then
        # Don't write under --dry-run; feed the engine via a temp file.
        SELECTIONS_FILE="$(mktemp -t mesh-selections.XXXXXX)"
        trap 'rm -f "${BOOTSTRAP_FOLLOWUP_FILE:-}" "'"$SELECTIONS_FILE"'"' EXIT
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
