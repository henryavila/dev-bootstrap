# shellcheck shell=bash
# 50-git shell fragment (zsh)
# Loaded by ~/.zshrc from ~/.zshrc.d/
# Shell-level git shortcuts. See bashrc.d-50-git.sh for rationale.
#
# All shortcuts delegate to `g` (not `git`) so the alias-tips plugin
# emits one concise reminder per command (e.g. "Alias tip: gs") instead
# of multiple noisy reminders for the underlying `git` form. `g='git'`
# keeps behavior identical — `g status` is just `git status`.

alias g='git'
alias gs='g status'
alias gl='g log --oneline --graph --decorate -15'
alias gd='g diff'
alias gds='g diff --staged'
alias gch='g checkout'
alias gb='g branch'
alias gp='g pull'
alias gaa='g add .'
alias gc='g commit'
alias grb='g rebase -i'
alias gsh='g show'
alias glog='g log --oneline --decorate --graph'
alias gloga='g log --oneline --decorate --graph --all'

# Destructive helper — resets everything, cleans untracked. Use with care.
alias whoops='g reset --hard && g clean -df'

# Sync main into current branch without losing your place
alias gmm='echo "Switching to main..." && g checkout main && echo -e "\nUpdating main..." && g pull && echo -e "\nReturning to previous branch..." && g checkout - && echo -e "\nMerging main..." && g merge main'

# zsh inherits git completion via compinit (which starship/ohmyzsh users already
# run). No equivalent to bash's __git_complete needed; `compdef _git g=git` works
# if you want explicit alias completion — left out here to stay minimal.
