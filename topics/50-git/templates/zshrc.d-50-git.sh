# 50-git shell fragment (zsh)
# Loaded by ~/.zshrc from ~/.zshrc.d/
# Shell-level git shortcuts. See bashrc.d-50-git.sh for rationale.

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

# zsh inherits git completion via compinit (which starship/ohmyzsh users already
# run). No equivalent to bash's __git_complete needed; `compdef _git g=git` works
# if you want explicit alias completion — left out here to stay minimal.
