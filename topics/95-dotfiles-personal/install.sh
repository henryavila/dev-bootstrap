#!/usr/bin/env bash
# 95-dotfiles-personal: clone $DOTFILES_REPO into $DOTFILES_DIR and run its install.sh.
# Gated by bootstrap.sh: skipped when DOTFILES_REPO is empty.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

: "${DOTFILES_REPO:?DOTFILES_REPO not set (bootstrap.sh should have skipped this topic)}"
: "${DOTFILES_DIR:=$HOME/dotfiles}"

# Optional create-from-template flow (gated by menu.sh). When the user
# answered "yes" to the template prompt, $CREATE_DOTFILES_FROM_TEMPLATE=1
# and the *_NEW_REPO_* vars carry the inputs. We invoke `gh repo create`
# here (rather than in the menu) because gh CLI is installed + authed by
# 05-identity, which has already completed by the time 95-* runs.
if [[ "${CREATE_DOTFILES_FROM_TEMPLATE:-0}" == "1" ]] && [[ ! -d "$DOTFILES_DIR/.git" ]]; then
    : "${DOTFILES_TEMPLATE_REPO:?CREATE_DOTFILES_FROM_TEMPLATE=1 but DOTFILES_TEMPLATE_REPO unset}"
    : "${DOTFILES_NEW_REPO_OWNER:?CREATE_DOTFILES_FROM_TEMPLATE=1 but DOTFILES_NEW_REPO_OWNER unset}"
    : "${DOTFILES_NEW_REPO_NAME:?CREATE_DOTFILES_FROM_TEMPLATE=1 but DOTFILES_NEW_REPO_NAME unset}"

    if ! command -v gh >/dev/null 2>&1; then
        followup critical "create-from-template requested, but \`gh\` CLI is not on PATH.
05-identity should have installed it earlier — re-run bootstrap with the
05-identity topic enabled, or run 'gh auth login' manually then:
    gh repo create $DOTFILES_NEW_REPO_OWNER/$DOTFILES_NEW_REPO_NAME \\
        --template $DOTFILES_TEMPLATE_REPO --clone --directory $DOTFILES_DIR"
        exit 1
    fi
    if ! gh auth status >/dev/null 2>&1; then
        followup critical "create-from-template requested, but gh is not authenticated.
Run 'gh auth login' (browser OAuth) and re-run bootstrap, or run manually:
    gh repo create $DOTFILES_NEW_REPO_OWNER/$DOTFILES_NEW_REPO_NAME \\
        --template $DOTFILES_TEMPLATE_REPO --clone --directory $DOTFILES_DIR"
        exit 1
    fi
    # gh auth status exits 0 even with missing scopes — verify a real API
    # call works before invoking 'gh repo create' so a failure surfaces with
    # a clear scope hint instead of an opaque GraphQL error from gh.
    if ! gh api user -q .login >/dev/null 2>&1; then
        followup critical "gh auth present but the API rejected our token (likely missing 'repo' or 'workflow' scope).
Run 'gh auth refresh -s repo,workflow' and re-run bootstrap, or invoke gh manually."
        exit 1
    fi

    visibility="--private"
    [[ "${DOTFILES_NEW_REPO_PRIVATE:-1}" == "0" ]] && visibility="--public"

    info "creating $DOTFILES_NEW_REPO_OWNER/$DOTFILES_NEW_REPO_NAME from template $DOTFILES_TEMPLATE_REPO ($visibility)"
    # shellcheck disable=SC2086
    # $visibility is a single flag; intentional word-split. If a future change
    # makes it carry multiple tokens (e.g. "--private --include-all-branches"),
    # convert to an array.
    if gh repo create "$DOTFILES_NEW_REPO_OWNER/$DOTFILES_NEW_REPO_NAME" \
        --template "$DOTFILES_TEMPLATE_REPO" \
        $visibility \
        --clone --directory "$DOTFILES_DIR"; then
        ok "created and cloned $DOTFILES_DIR"
    else
        followup critical "gh repo create failed.
Check that $DOTFILES_NEW_REPO_OWNER/$DOTFILES_NEW_REPO_NAME does not already exist
(or pick a new name) and that gh auth has 'repo' + 'workflow' scopes.
Re-run bootstrap with the same answers, or invoke gh manually."
        exit 1
    fi
fi

if [[ -d "$DOTFILES_DIR/.git" ]]; then
    info "pulling updates in $DOTFILES_DIR"
    git -C "$DOTFILES_DIR" pull --ff-only || warn "could not fast-forward; leaving as-is"
else
    if [[ -e "$DOTFILES_DIR" ]]; then
        fail "$DOTFILES_DIR exists and is not a git repo — move or delete it first"
        exit 1
    fi
    info "cloning $DOTFILES_REPO → $DOTFILES_DIR"
    git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
fi

if [[ -f "$DOTFILES_DIR/install.sh" ]]; then
    info "running $DOTFILES_DIR/install.sh"
    bash "$DOTFILES_DIR/install.sh"
else
    warn "$DOTFILES_DIR/install.sh not found — dotfiles cloned but not applied"
fi

ok "95-dotfiles-personal done"
