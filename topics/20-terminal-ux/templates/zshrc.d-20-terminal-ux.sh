# 20-terminal-ux shell fragment (zsh)
# Loaded by ~/.zshrc from ~/.zshrc.d/

if command -v starship >/dev/null 2>&1; then
    eval "$(starship init zsh)"
fi

if command -v zoxide >/dev/null 2>&1; then
    eval "$(zoxide init zsh)"
fi

# fzf integration (brew install fzf installs shell-integration in these paths)
for f in \
    /opt/homebrew/opt/fzf/shell/key-bindings.zsh \
    /opt/homebrew/opt/fzf/shell/completion.zsh \
    /usr/local/opt/fzf/shell/key-bindings.zsh \
    /usr/local/opt/fzf/shell/completion.zsh \
    /usr/share/doc/fzf/examples/key-bindings.zsh \
    /usr/share/doc/fzf/examples/completion.zsh; do
    [ -f "$f" ] && source "$f"
done

if command -v eza >/dev/null 2>&1; then
    alias ls='eza'
    alias ll='eza -l --git'
    alias la='eza -la --git'
    alias tree='eza --tree'
fi

if command -v bat >/dev/null 2>&1; then
    alias cat='bat --style=plain --paging=never'
elif command -v batcat >/dev/null 2>&1; then
    alias bat='batcat'
    alias cat='batcat --style=plain --paging=never'
fi

if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
    alias fd='fdfind'
fi
