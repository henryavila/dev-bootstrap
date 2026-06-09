#!/usr/bin/env bash
# personal/apply: clone $MESH_IDENTITY_REPO + run its install.sh.
# Custom item contract — engine sources this and calls check()/install()/verify().
# Marked idempotent in the manifest: the identity repo is re-applied on every run
# (identity_ensure_repo pulls, the fork's install.sh is itself idempotent).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/log.sh"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/identity-repo.sh"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/topic-cleanup.sh"

# True when a controlling terminal is reachable (works even under the engine's
# `... | tee LOG` pipe, where [ -t 1 ] is false — see tty_detection_under_tee_pipe).
_has_tty() { : </dev/tty >/dev/null 2>&1; }

# Interactive onboarding when no identity repo is configured AND none is cloned.
# Either collects an existing repo URL, or the inputs for a create-from-template
# (the backend in identity-repo.sh does the gh-auth check + `gh repo create`).
# Sets MESH_IDENTITY_REPO and/or CREATE_IDENTITY_FROM_TEMPLATE + MESH_IDENTITY_NEW_REPO_*.
_prompt_identity_repo() {
    local ans tmpl owner name priv def_owner
    printf '\n' >/dev/tty
    info "No mesh-identity repo is configured for this machine."
    printf 'Create a new private repo from a GitHub template? [y/N] ' >/dev/tty
    read -r ans </dev/tty || ans=""

    if [[ "$ans" =~ ^[Yy] ]]; then
        printf 'Template repo (owner/name, e.g. henryavila/dotfiles-template): ' >/dev/tty
        read -r tmpl </dev/tty || tmpl=""
        if [[ -z "$tmpl" ]]; then
            warn "no template given — skipping identity create"
            return 0
        fi
        def_owner="$(gh api user -q .login 2>/dev/null || true)"
        printf 'New repo owner [%s]: ' "${def_owner:-your-gh-login}" >/dev/tty
        read -r owner </dev/tty || owner=""
        owner="${owner:-$def_owner}"
        printf 'New repo name [mesh-identity]: ' >/dev/tty
        read -r name </dev/tty || name=""
        name="${name:-mesh-identity}"
        printf 'Private? [Y/n] ' >/dev/tty
        read -r priv </dev/tty || priv=""

        export CREATE_IDENTITY_FROM_TEMPLATE=1
        export MESH_IDENTITY_TEMPLATE_REPO="$tmpl"
        export MESH_IDENTITY_NEW_REPO_OWNER="$owner"
        export MESH_IDENTITY_NEW_REPO_NAME="$name"
        [[ "$priv" =~ ^[Nn] ]] && export MESH_IDENTITY_NEW_REPO_PRIVATE=0 || export MESH_IDENTITY_NEW_REPO_PRIVATE=1
        export MESH_IDENTITY_REPO="$owner/$name"   # satisfies downstream + records the new repo
    else
        printf 'Existing mesh-identity repo (URL or owner/name), blank to skip: ' >/dev/tty
        local url; read -r url </dev/tty || url=""
        [[ -n "$url" ]] && export MESH_IDENTITY_REPO="$url"
    fi
}

check() {
    # Idempotent apply — always run (manifest idempotent: true). The identity
    # fork's own install.sh handles the "already applied" fast paths.
    return 1
}

install() { (
    set -euo pipefail

    : "${MESH_IDENTITY_DIR:=$HOME/mesh-identity}"

    # Resolve the identity repo, in priority order:
    #   1. MESH_IDENTITY_REPO set (menu option / env / default_from) → clone+pull.
    #   2. An existing checkout at $MESH_IDENTITY_DIR → reuse it (derive the URL).
    #   3. Interactive TTY → onboarding prompt (existing URL, or create-from-template).
    #   4. Nothing → fail with an actionable message.
    if [[ -z "${MESH_IDENTITY_REPO:-}" ]]; then
        if [[ -d "$MESH_IDENTITY_DIR/.git" ]]; then
            MESH_IDENTITY_REPO="$(git -C "$MESH_IDENTITY_DIR" remote get-url origin 2>/dev/null || true)"
            info "using the existing identity checkout at $MESH_IDENTITY_DIR"
        elif [[ "${NON_INTERACTIVE:-0}" != "1" ]] && _has_tty; then
            _prompt_identity_repo
        fi
    fi

    if [[ -z "${MESH_IDENTITY_REPO:-}" && "${CREATE_IDENTITY_FROM_TEMPLATE:-0}" != "1" && ! -d "$MESH_IDENTITY_DIR/.git" ]]; then
        fail "no mesh-identity repo: set it in the 'Personal identity' options, export MESH_IDENTITY_REPO, or run setup.sh interactively to create one"
        return 1
    fi

    identity_ensure_repo "${MESH_IDENTITY_REPO:-}" "$MESH_IDENTITY_DIR"

    if [[ -f "$MESH_IDENTITY_DIR/install.sh" ]]; then
        info "running $MESH_IDENTITY_DIR/install.sh"
        MESH_NPM_GLOBAL="${MESH_NPM_GLOBAL:-0}" bash "$MESH_IDENTITY_DIR/install.sh"
    else
        warn "$MESH_IDENTITY_DIR/install.sh not found — identity repo cloned but not applied"
    fi

    # Drift cleanup: artifacts the identity fork used to install but no longer
    # does. Reads data/uninstall.list and removes each entry. Idempotent.
    uninstall_apply "$HERE/data/uninstall.list"

    ok "personal identity done"
) }

verify() {
    [ -d "${MESH_IDENTITY_DIR:-$HOME/mesh-identity}" ]
}

rollback() {
    # Never auto-remove the user's applied identity layer.
    :
}
