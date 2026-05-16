#!/usr/bin/env bash
# Helpers for topics that need a local dotfiles checkout.
# Source this file after lib/log.sh.

dotfiles_ensure_repo() {
    local dotfiles_repo="$1"
    local dotfiles_dir="$2"

    : "${dotfiles_repo:?dotfiles_ensure_repo requires a repository URL}"
    : "${dotfiles_dir:?dotfiles_ensure_repo requires a destination directory}"

    # Optional create-from-template flow (gated by menu.sh). When the user
    # answered "yes" to the template prompt, $CREATE_DOTFILES_FROM_TEMPLATE=1
    # and the *_NEW_REPO_* vars carry the inputs. We invoke `gh repo create`
    # from here because gh CLI is installed + authed by 05-identity before any
    # dotfiles-backed opt-in topic runs.
    if [[ "${CREATE_DOTFILES_FROM_TEMPLATE:-0}" == "1" ]] && [[ ! -d "$dotfiles_dir/.git" ]]; then
        : "${DOTFILES_TEMPLATE_REPO:?CREATE_DOTFILES_FROM_TEMPLATE=1 but DOTFILES_TEMPLATE_REPO unset}"
        : "${DOTFILES_NEW_REPO_OWNER:?CREATE_DOTFILES_FROM_TEMPLATE=1 but DOTFILES_NEW_REPO_OWNER unset}"
        : "${DOTFILES_NEW_REPO_NAME:?CREATE_DOTFILES_FROM_TEMPLATE=1 but DOTFILES_NEW_REPO_NAME unset}"

        if ! command -v gh >/dev/null 2>&1; then
            followup critical "create-from-template requested, but \`gh\` CLI is not on PATH.
05-identity should have installed it earlier — re-run bootstrap with the
05-identity topic enabled, or run 'gh auth login' manually then:
    gh repo create $DOTFILES_NEW_REPO_OWNER/$DOTFILES_NEW_REPO_NAME \\
        --template $DOTFILES_TEMPLATE_REPO --clone --directory $dotfiles_dir"
            return 1
        fi
        if ! gh auth status >/dev/null 2>&1; then
            followup critical "create-from-template requested, but gh is not authenticated.
Run 'gh auth login' (browser OAuth) and re-run bootstrap, or run manually:
    gh repo create $DOTFILES_NEW_REPO_OWNER/$DOTFILES_NEW_REPO_NAME \\
        --template $DOTFILES_TEMPLATE_REPO --clone --directory $dotfiles_dir"
            return 1
        fi
        # gh auth status exits 0 even with missing scopes — verify a real API
        # call works before invoking 'gh repo create' so a failure surfaces with
        # a clear scope hint instead of an opaque GraphQL error from gh.
        if ! gh api user -q .login >/dev/null 2>&1; then
            followup critical "gh auth present but the API rejected our token (likely missing 'repo' or 'workflow' scope).
Run 'gh auth refresh -s repo,workflow' and re-run bootstrap, or invoke gh manually."
            return 1
        fi

        local -a visibility
        visibility=("--private")
        [[ "${DOTFILES_NEW_REPO_PRIVATE:-1}" == "0" ]] && visibility=("--public")

        info "creating $DOTFILES_NEW_REPO_OWNER/$DOTFILES_NEW_REPO_NAME from template $DOTFILES_TEMPLATE_REPO (${visibility[*]})"
        if gh repo create "$DOTFILES_NEW_REPO_OWNER/$DOTFILES_NEW_REPO_NAME" \
            --template "$DOTFILES_TEMPLATE_REPO" \
            "${visibility[@]}" \
            --clone --directory "$dotfiles_dir"; then
            ok "created and cloned $dotfiles_dir"
        else
            followup critical "gh repo create failed.
Check that $DOTFILES_NEW_REPO_OWNER/$DOTFILES_NEW_REPO_NAME does not already exist
(or pick a new name) and that gh auth has 'repo' + 'workflow' scopes.
Re-run bootstrap with the same answers, or invoke gh manually."
            return 1
        fi
    fi

    if [[ -d "$dotfiles_dir/.git" ]]; then
        info "pulling updates in $dotfiles_dir"
        git -C "$dotfiles_dir" pull --ff-only || warn "could not fast-forward; leaving as-is"
    else
        if [[ -e "$dotfiles_dir" ]]; then
            fail "$dotfiles_dir exists and is not a git repo — move or delete it first"
            return 1
        fi
        info "cloning $dotfiles_repo → $dotfiles_dir"
        git clone "$dotfiles_repo" "$dotfiles_dir"
    fi
}
