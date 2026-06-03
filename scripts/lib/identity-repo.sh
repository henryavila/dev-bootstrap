#!/usr/bin/env bash
# Helpers for topics that need a local identity checkout.
# Source this file after lib/log.sh.

identity_ensure_repo() {
    local repo_url="$1"
    local repo_dir="$2"

    : "${repo_dir:?identity_ensure_repo requires a destination directory}"
    # repo_url may legitimately be empty when (a) creating from a template
    # (CREATE_IDENTITY_FROM_TEMPLATE=1, inputs in *_NEW_REPO_*) or (b) the repo is
    # already cloned at repo_dir (we just pull). Only the fresh-clone path needs it.
    if [[ "${CREATE_IDENTITY_FROM_TEMPLATE:-0}" != "1" && ! -d "$repo_dir/.git" ]]; then
        : "${repo_url:?identity_ensure_repo requires a repository URL (or an existing checkout / CREATE_IDENTITY_FROM_TEMPLATE=1)}"
    fi

    # Optional create-from-template flow (gated by menu.sh). When the user
    # answered "yes" to the template prompt, $CREATE_IDENTITY_FROM_TEMPLATE=1
    # and the *_NEW_REPO_* vars carry the inputs. We invoke `gh repo create`
    # from here because gh CLI is installed + authed by identity before any
    # identity-backed opt-in topic runs.
    if [[ "${CREATE_IDENTITY_FROM_TEMPLATE:-0}" == "1" ]] && [[ ! -d "$repo_dir/.git" ]]; then
        : "${MESH_IDENTITY_TEMPLATE_REPO:?CREATE_IDENTITY_FROM_TEMPLATE=1 but MESH_IDENTITY_TEMPLATE_REPO unset}"
        : "${MESH_IDENTITY_NEW_REPO_OWNER:?CREATE_IDENTITY_FROM_TEMPLATE=1 but MESH_IDENTITY_NEW_REPO_OWNER unset}"
        : "${MESH_IDENTITY_NEW_REPO_NAME:?CREATE_IDENTITY_FROM_TEMPLATE=1 but MESH_IDENTITY_NEW_REPO_NAME unset}"

        if ! command -v gh >/dev/null 2>&1; then
            followup critical "create-from-template requested, but \`gh\` CLI is not on PATH.
identity should have installed it earlier — re-run bootstrap with the
identity topic enabled, or run 'gh auth login' manually then:
    gh repo create $MESH_IDENTITY_NEW_REPO_OWNER/$MESH_IDENTITY_NEW_REPO_NAME \\
        --template $MESH_IDENTITY_TEMPLATE_REPO --clone --directory $repo_dir"
            return 1
        fi
        if ! gh auth status >/dev/null 2>&1; then
            followup critical "create-from-template requested, but gh is not authenticated.
Run 'gh auth login' (browser OAuth) and re-run bootstrap, or run manually:
    gh repo create $MESH_IDENTITY_NEW_REPO_OWNER/$MESH_IDENTITY_NEW_REPO_NAME \\
        --template $MESH_IDENTITY_TEMPLATE_REPO --clone --directory $repo_dir"
            return 1
        fi
        if ! gh api user -q .login >/dev/null 2>&1; then
            followup critical "gh auth present but the API rejected our token (likely missing 'repo' or 'workflow' scope).
Run 'gh auth refresh -s repo,workflow' and re-run bootstrap, or invoke gh manually."
            return 1
        fi

        local -a visibility
        visibility=("--private")
        [[ "${MESH_IDENTITY_NEW_REPO_PRIVATE:-1}" == "0" ]] && visibility=("--public")

        info "creating $MESH_IDENTITY_NEW_REPO_OWNER/$MESH_IDENTITY_NEW_REPO_NAME from template $MESH_IDENTITY_TEMPLATE_REPO (${visibility[*]})"
        if gh repo create "$MESH_IDENTITY_NEW_REPO_OWNER/$MESH_IDENTITY_NEW_REPO_NAME" \
            --template "$MESH_IDENTITY_TEMPLATE_REPO" \
            "${visibility[@]}" \
            --clone --directory "$repo_dir"; then
            ok "created and cloned $repo_dir"
        else
            followup critical "gh repo create failed.
Check that $MESH_IDENTITY_NEW_REPO_OWNER/$MESH_IDENTITY_NEW_REPO_NAME does not already exist
(or pick a new name) and that gh auth has 'repo' + 'workflow' scopes.
Re-run bootstrap with the same answers, or invoke gh manually."
            return 1
        fi
    fi

    if [[ -d "$repo_dir/.git" ]]; then
        info "pulling updates in $repo_dir"
        git -C "$repo_dir" pull --ff-only || warn "could not fast-forward; leaving as-is"
    else
        if [[ -e "$repo_dir" ]]; then
            fail "$repo_dir exists and is not a git repo — move or delete it first"
            return 1
        fi
        # The onboarding UI advertises "URL or owner/name", but `git clone
        # owner/name` is not a valid transport. Expand a bare owner/name: prefer
        # `gh repo clone` (honors the user's gh auth + ssh/https preference), else
        # the public https URL. A real URL / scp form is cloned as-is.
        if [[ "$repo_url" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
            if command -v gh >/dev/null 2>&1; then
                info "cloning $repo_url (gh) → $repo_dir"
                gh repo clone "$repo_url" "$repo_dir"
            else
                info "cloning https://github.com/$repo_url.git → $repo_dir"
                git clone "https://github.com/$repo_url.git" "$repo_dir"
            fi
        else
            info "cloning $repo_url → $repo_dir"
            git clone "$repo_url" "$repo_dir"
        fi
    fi
}
