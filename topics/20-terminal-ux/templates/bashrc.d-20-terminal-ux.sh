# 20-terminal-ux shell fragment (bash)
# Loaded by ~/.bashrc from ~/.bashrc.d/

# starship prompt
if command -v starship >/dev/null 2>&1; then
    eval "$(starship init bash)"
fi

# zoxide (z shortcut)
if command -v zoxide >/dev/null 2>&1; then
    eval "$(zoxide init bash)"
fi

# fzf keybindings (Ctrl+R history, Ctrl+T file finder, Alt+C dir jump)
if [ -f /usr/share/doc/fzf/examples/key-bindings.bash ]; then
    # Ubuntu / Debian
    source /usr/share/doc/fzf/examples/key-bindings.bash
    [ -f /usr/share/doc/fzf/examples/completion.bash ] && source /usr/share/doc/fzf/examples/completion.bash
elif [ -f /opt/homebrew/opt/fzf/shell/key-bindings.bash ]; then
    # Mac ARM
    source /opt/homebrew/opt/fzf/shell/key-bindings.bash
    source /opt/homebrew/opt/fzf/shell/completion.bash
elif [ -f /usr/local/opt/fzf/shell/key-bindings.bash ]; then
    # Mac Intel / custom prefix fallback
    source /usr/local/opt/fzf/shell/key-bindings.bash
    source /usr/local/opt/fzf/shell/completion.bash
fi

# Aliases for modern replacements
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
