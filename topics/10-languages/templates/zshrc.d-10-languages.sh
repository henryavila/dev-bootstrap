# shellcheck shell=bash
# 10-languages shell fragment (zsh)
# Loaded by ~/.zshrc from ~/.zshrc.d/

# fnm
if [ -s "$HOME/.local/share/fnm/fnm" ]; then
    export PATH="$HOME/.local/share/fnm:$PATH"
fi
if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --use-on-cd)"
fi

# Composer global bin
if [ -d "$HOME/.composer/vendor/bin" ]; then
    export PATH="$HOME/.composer/vendor/bin:$PATH"
fi
