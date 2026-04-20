# 50-git shell fragment (bash)
# Loaded by ~/.bashrc from ~/.bashrc.d/
# Shell-level git shortcuts. These complement the `git config alias.*` entries
# that topic 50-git installs in ~/.gitconfig (e.g. `git co`, `git st`) — those
# work inside `git`; these work at the shell prompt directly.

alias g='git'
alias gs='git status'
alias gl='git log --oneline --graph --decorate -15'
alias gd='git diff'
alias gds='git diff --staged'
alias gco='git checkout'
alias gb='git branch'
alias gp='git pull'
alias gaa='git add .'
alias gc='git commit'
alias grb='git rebase -i'
alias gsh='git show'
alias glog='git log --oneline --decorate --graph'
alias gloga='git log --oneline --decorate --graph --all'

# Destructive helper — resets everything, cleans untracked. Use with care.
alias whoops='git reset --hard && git clean -df'

# Sync main into current branch without losing your place
alias gmm='echo "Switching to main..." && git checkout main && echo -e "\nUpdating main..." && git pull && echo -e "\nReturning to previous branch..." && git checkout - && echo -e "\nMerging main..." && git merge main'

# Extend git completion to cover the shortcut aliases (bash-only).
# __git_complete is provided by the bash-completion package + git's contrib/completion.
if type __git_complete &>/dev/null; then
    __git_complete g   __git_main
    __git_complete gco _git_checkout
    __git_complete gb  _git_branch
    __git_complete gp  _git_pull
    __git_complete gd  _git_diff
fi
