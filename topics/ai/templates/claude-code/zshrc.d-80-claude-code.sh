# shellcheck shell=bash
# ~/.zshrc.d/80-claude-code.sh — puts Bun + Claude Code in PATH.
# Mirror of the bash fragment. See bashrc.d-80-claude-code.sh for
# the full rationale (crc 2026-04-23 bun-not-in-PATH bug).

# Bun runtime
if [ -x "$HOME/.bun/bin/bun" ]; then
    export BUN_INSTALL="$HOME/.bun"
    case ":$PATH:" in *":$BUN_INSTALL/bin:"*) ;; *) export PATH="$BUN_INSTALL/bin:$PATH";; esac
    # Bun ships a zsh completion script at $BUN_INSTALL/_bun
    [ -s "$BUN_INSTALL/_bun" ] && source "$BUN_INSTALL/_bun"
fi

# Claude Code CLI
if [ -x "$HOME/.local/bin/claude" ]; then
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac
fi
