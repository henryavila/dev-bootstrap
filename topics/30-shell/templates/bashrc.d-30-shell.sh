# shellcheck shell=bash
# 30-shell shell fragment (bash)
# Fundamentals every dev wants: bash completion, dircolors, sane defaults.
# Loaded by ~/.bashrc from ~/.bashrc.d/ (ordered alphabetically — 30 runs
# AFTER 10-languages and 20-terminal-ux but BEFORE user overrides in
# ~/.bashrc.local).

# ---------- Bash programmable completion ----------
if ! shopt -oq posix 2>/dev/null; then
    if [ -f /usr/share/bash-completion/bash_completion ]; then
        . /usr/share/bash-completion/bash_completion
    elif [ -f /etc/bash_completion ]; then
        . /etc/bash_completion
    elif [ -f /opt/homebrew/etc/profile.d/bash_completion.sh ]; then
        . /opt/homebrew/etc/profile.d/bash_completion.sh
    elif [ -f /usr/local/etc/profile.d/bash_completion.sh ]; then
        . /usr/local/etc/profile.d/bash_completion.sh
    fi
fi

# ---------- dircolors — populates $LS_COLORS even when eza isn't used ----------
if command -v dircolors >/dev/null 2>&1; then
    if [ -r "$HOME/.dircolors" ]; then
        eval "$(dircolors -b "$HOME/.dircolors")"
    else
        eval "$(dircolors -b)"
    fi
fi

# ---------- Extra shell options ----------
shopt -s globstar 2>/dev/null || true

# ---------- Grep colored ----------
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
