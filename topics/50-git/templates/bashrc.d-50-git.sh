# shellcheck shell=bash
# 50-git shell fragment (bash)
# Loaded by ~/.bashrc from ~/.bashrc.d/
# Shell-level git shortcuts. These complement the `git config alias.*` entries
# that topic 50-git installs in ~/.gitconfig (e.g. `git st`, `git br`) — those
# work inside `git`; these work at the shell prompt directly.
#
# All shortcuts delegate to `g` (not `git`) so that the zsh-you-should-use
# (YSU) plugin stays quiet — YSU detects "you should use 'g' instead of 'git'"
# by matching alias values against the typed/expanded command. Using `g` as
# the base in alias values silences that warning while preserving identical
# behavior (since `g='git'`, `g status` still ends up as `git status`).

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

# Extend git completion to cover the shortcut aliases (bash-only).
# __git_complete is provided by the bash-completion package + git's contrib/completion.
if type __git_complete &>/dev/null; then
    __git_complete g   __git_main
    __git_complete gch _git_checkout
    __git_complete gb  _git_branch
    __git_complete gp  _git_pull
    __git_complete gd  _git_diff
fi
