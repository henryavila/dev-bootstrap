# Driver: git-clone. Clones spec into GIT_CLONE_DEST or $HOME/<basename>.
git_clone_check()   { [[ -d "${GIT_CLONE_DEST:-$HOME/$(basename "$1" .git)}" ]]; }
git_clone_install() { git clone --depth 1 "$1" "${GIT_CLONE_DEST:-$HOME/$(basename "$1" .git)}"; }
