#!/usr/bin/env bash
# scripts/lib/init.sh — `mesh init` subcommand: 4-mode identity onboarding.
#
# Modes (per spec C13.2):
#   adopt-url <URL>  | --identity-repo <URL> | --identity-repo=<URL>
#       git clone existing identity by URL, then run identity install.sh.
#   create-new       | --create-identity
#       scaffold from $WS_ROOT/template/, strip .example, substitute the
#       3 placeholders (__USER_NAME__/__USER_EMAIL__/__GH_USERNAME__),
#       optional gh repo create, then run identity install.sh.
#   skip             | --no-identity | --skip
#       bootstrap workstation only — no identity setup.
#   interactive      | (no arg, TTY)
#       whiptail menu (plain fallback if whiptail missing) → dispatches.
#
# Idempotent: existing $MESH_IDENTITY_DIR ⇒ exit 0 with informational msg.
# Non-TTY without a mode flag exits 2 (no interactive guessing).
#
# Env:
#   MESH_IDENTITY_DIR   target dir (default $HOME/mesh-identity)
#   MESH_TEMPLATE_DIR   template source (default $WS_ROOT/template)
#   MESH_INIT_NO_GH=1   suppress optional `gh repo create` in create-new
#   GIT_NAME/GIT_EMAIL/MESH_INIT_GH_USER  non-interactive create-new inputs
#
# Spec: §C13. Phase 6 Task 6.2.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_ROOT="$(cd "$HERE/../.." && pwd)"
TEMPLATE_DIR="${MESH_TEMPLATE_DIR:-$WS_ROOT/template}"
IDENTITY_DIR="${MESH_IDENTITY_DIR:-$HOME/mesh-identity}"

# Reusable interactive prompts (blink-styled fields + confirm helpers).
# shellcheck source=/dev/null
. "$HERE/log.sh"

_die()  { printf 'mesh init: %s\n' "$*" >&2; exit 2; }
_info() { printf '==> %s\n' "$*"; }

_print_help() {
    cat <<'EOF'
Usage: mesh init [MODE | FLAGS]

MODES (positional, internal):
  adopt-url <URL>      Clone existing identity by URL
  create-new           Scaffold new identity from template/
  skip                 Bootstrap workstation only
  interactive          Prompt menu (default on TTY)

FLAGS (external, forwarded by curl-pipe `install`):
  --identity-repo <URL>   = adopt-url
  --create-identity       = create-new
  --no-identity, --skip   = skip
  --name <NAME>           override gh repo name (with --create-identity)
  --private               accepted (default; identity is always private)
  -h, --help              this text

ENV:
  MESH_IDENTITY_DIR     target dir          (default $HOME/mesh-identity)
  MESH_TEMPLATE_DIR     template source     (default $WS_ROOT/template)
  MESH_INIT_NO_GH=1     skip optional `gh repo create`
  GIT_NAME/GIT_EMAIL    non-interactive create-new inputs
  MESH_INIT_GH_USER     non-interactive create-new GitHub username
EOF
}

_run_identity_install() {
    if [[ -x "$IDENTITY_DIR/install.sh" ]]; then
        _info "running identity install.sh"
        bash "$IDENTITY_DIR/install.sh" \
            || _die "identity install.sh failed (exit $?)"
    elif [[ -f "$IDENTITY_DIR/install.sh" ]]; then
        _info "identity install.sh exists but not executable — running via bash"
        bash "$IDENTITY_DIR/install.sh" \
            || _die "identity install.sh failed (exit $?)"
    else
        _info "no install.sh in identity — skipping deploy step"
    fi
}

_adopt_url() {
    local url="${1:-}"
    [[ -n "$url" ]] || _die "adopt-url requires URL"
    command -v git >/dev/null 2>&1 || _die "git not in PATH"
    _info "cloning $url → $IDENTITY_DIR"
    git clone "$url" "$IDENTITY_DIR" \
        || _die "git clone failed: $url"
    _info "identity ready at $IDENTITY_DIR"
    _run_identity_install
}

_create_new() {
    [[ -d "$TEMPLATE_DIR" ]] || _die "template/ missing at $TEMPLATE_DIR (Phase 6 Task 6.3)"

    local user_name="${GIT_NAME:-}"
    local user_email="${GIT_EMAIL:-}"
    local gh_user="${MESH_INIT_GH_USER:-}"
    if [[ -t 0 ]]; then
        [[ -n "$user_name"  ]] || user_name="$(ask_line 'Your name')"
        [[ -n "$user_email" ]] || user_email="$(ask_line 'Your email')"
        [[ -n "$gh_user"    ]] || gh_user="$(ask_line 'GitHub username')"
    fi
    [[ -n "$user_name" && -n "$user_email" && -n "$gh_user" ]] \
        || _die "create-new needs name/email/gh_user (set GIT_NAME/GIT_EMAIL/MESH_INIT_GH_USER for non-interactive)"

    _info "scaffolding identity from $TEMPLATE_DIR → $IDENTITY_DIR"
    mkdir -p "$(dirname "$IDENTITY_DIR")" \
        || _die "mkdir parent of $IDENTITY_DIR failed"
    cp -R "$TEMPLATE_DIR" "$IDENTITY_DIR" \
        || _die "cp -R template to $IDENTITY_DIR failed"

    # Drop template-meta files (README*, .keep) — they're for workstation
    # developers, not identity owners. L11 lint allowlists these in template/;
    # we mirror that exclusion on copy.
    find "$IDENTITY_DIR" -type f \
        \( \( -iname 'README*' ! -name '*.example' \) -o -name '.keep' \) -delete 2>/dev/null || true

    # Strip .example suffix on every remaining file.
    while IFS= read -r -d '' f; do
        mv "$f" "${f%.example}" \
            || _die "strip-example mv failed: $f"
    done < <(find "$IDENTITY_DIR" -type f -name '*.example' -print0)

    # Substitute the 3 placeholders across text files only (skip binary).
    while IFS= read -r -d '' f; do
        if grep -Iq . "$f" 2>/dev/null; then
            sed -i.bak \
                -e "s|__USER_NAME__|$user_name|g" \
                -e "s|__USER_EMAIL__|$user_email|g" \
                -e "s|__GH_USERNAME__|$gh_user|g" \
                "$f" \
                || _die "sed substitute failed: $f"
            rm -f "$f.bak"
        fi
    done < <(find "$IDENTITY_DIR" -type f -print0)

    _info "placeholders substituted (__USER_NAME__/__USER_EMAIL__/__GH_USERNAME__)"

    # Optional `gh repo create` flow (skipped when MESH_INIT_NO_GH set / no TTY / no gh).
    if [[ -z "${MESH_INIT_NO_GH:-}" ]] && command -v gh >/dev/null 2>&1 && [[ -t 0 ]]; then
        if confirm "Create private repo gh:$gh_user/${MESH_INIT_REPO_NAME:-mesh-identity}?"; then
            (
                cd "$IDENTITY_DIR" \
                    && git init -q \
                    && git add -A \
                    && git commit -q -m "init: bootstrapped from mesh-workstation template"
            ) || _die "local git init/commit in $IDENTITY_DIR failed"
            gh repo create "$gh_user/${MESH_INIT_REPO_NAME:-mesh-identity}" \
                --private --source "$IDENTITY_DIR" --push \
                || _die "gh repo create $gh_user/${MESH_INIT_REPO_NAME:-mesh-identity} failed"
        fi
    fi

    _run_identity_install
}

_interactive_select() {
    [[ -t 0 && -t 1 ]] \
        || _die "no mode flag + no TTY — pass --identity-repo / --create-identity / --no-identity"
    local choice="" url=""
    if command -v whiptail >/dev/null 2>&1; then
        choice=$(whiptail --title "mesh init" --menu "Identity source:" 15 60 4 \
            "1" "Adopt existing identity by URL" \
            "2" "Create new identity from template" \
            "3" "Skip (workstation only)" \
            3>&2 2>&1 1>&3) || { _info "cancelled"; exit 0; }
    else
        echo "mesh init — identity source:"
        echo "  1) Adopt existing identity by URL"
        echo "  2) Create new identity from template"
        echo "  3) Skip"
        choice="$(ask_line 'Choose [1-3]')"
    fi
    case "$choice" in
        1) url="$(ask_line 'Identity URL')"; _adopt_url "$url" ;;
        2) _create_new ;;
        3) _info "skipped"; exit 0 ;;
        *) _die "invalid choice '$choice'" ;;
    esac
}

# ─── Parse args ──────────────────────────────────────────────────
mode=""
adopt_url_arg=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        adopt-url)              mode="adopt-url"; adopt_url_arg="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
        create-new)             mode="create-new"; shift ;;
        skip)                   mode="skip"; shift ;;
        interactive)            mode="interactive"; shift ;;
        --identity-repo)        mode="adopt-url"; adopt_url_arg="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
        --identity-repo=*)      mode="adopt-url"; adopt_url_arg="${1#--identity-repo=}"; shift ;;
        --create-identity)      mode="create-new"; shift ;;
        --no-identity|--skip)   mode="skip"; shift ;;
        --name)                 export MESH_INIT_REPO_NAME="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
        --private)              shift ;;
        -h|--help)              _print_help; exit 0 ;;
        *)                      _die "unknown arg '$1' (try -h)" ;;
    esac
done

# ─── Idempotency ──────────────────────────────────────────────────
if [[ -d "$IDENTITY_DIR" ]]; then
    _info "identity already exists at $IDENTITY_DIR — skipping init"
    exit 0
fi

# ─── Dispatch ─────────────────────────────────────────────────────
case "${mode:-interactive}" in
    skip)         _info "skipped (mode=skip)"; exit 0 ;;
    adopt-url)    _adopt_url "$adopt_url_arg" ;;
    create-new)   _create_new ;;
    interactive)  _interactive_select ;;
    *)            _die "unreachable: mode='$mode'" ;;
esac

_info "mesh init complete"
