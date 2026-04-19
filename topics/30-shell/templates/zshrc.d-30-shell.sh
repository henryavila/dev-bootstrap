# 30-shell shell fragment (zsh)
# zsh equivalents of the bash fragment: completion + dircolors + grep aliases.
# zsh has its own globstar-like glob built-in (extended_glob); enable it.

# ---------- Extended globbing (zsh's equivalent of bash `shopt -s globstar`) ----------
setopt extended_glob 2>/dev/null || true
setopt null_glob 2>/dev/null || true

# ---------- bash-completion is bash-only; zsh has compinit (already run in the zshrc loader) ----------

# ---------- dircolors ----------
if command -v dircolors >/dev/null 2>&1; then
    if [ -r "$HOME/.dircolors" ]; then
        eval "$(dircolors -b "$HOME/.dircolors")"
    else
        eval "$(dircolors -b)"
    fi
fi

# ---------- Grep colored ----------
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
