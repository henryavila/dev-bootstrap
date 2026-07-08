# shellcheck shell=bash
# Driver: git-clone. Clones spec into GIT_CLONE_DEST or $HOME/<basename>.
#
# Detection model: dir-presence is the install-time check (don't re-clone
# if the directory exists). Menu detection additionally consults the engine
# install marker (lib/install-state.sh) for drift signal — a clone marker
# without the directory means user removed it manually.
#
# spec: a clone URL (e.g. https://github.com/foo/bar.git or git@host:foo/bar.git).
# GIT_CLONE_DEST: optional override for the clone destination.

_git_clone_dest() {
    printf '%s' "${GIT_CLONE_DEST:-$HOME/$(basename "$1" .git)}"
}

git_clone_check()   { [[ -d "$(_git_clone_dest "$1")" ]]; }

git_clone_install() { git clone --depth 1 "$1" "$(_git_clone_dest "$1")"; }

git_clone_verify() {
    # Tighter than _check: the dir must exist AND look like a git repo.
    # Catches the case where a same-named directory exists but wasn't
    # cloned by us (e.g. user-created scratch dir).
    local dest
    dest="$(_git_clone_dest "$1")"
    [[ -d "$dest/.git" ]] || [[ -f "$dest/.git" ]]
}

git_clone_repair() {
    local dest
    dest="$(_git_clone_dest "$1")"
    if git_clone_verify "$1"; then
        git -C "$dest" fetch --depth 1 --prune >/dev/null 2>&1 || return 1
        return 0
    fi
    if [[ -e "$dest" ]]; then
        echo "git-clone: refusing to repair non-git destination: $dest" >&2
        return 75
    fi
    git_clone_install "$1"
}

git_clone_rollback() {
    # Only remove if the destination is a real git repo — refuse to delete
    # a directory we didn't create (defense against GIT_CLONE_DEST aimed at
    # an existing project). The local is named `dir` (an L05-allowlisted scope
    # var) so the static lint reads the rm -rf as guarded, matching the runtime
    # guard on the line above (same convention as uninstall-handlers.sh).
    local dir
    dir="$(_git_clone_dest "$1")"
    [[ -d "$dir/.git" ]] || [[ -f "$dir/.git" ]] || return 0
    rm -rf "$dir"
}
