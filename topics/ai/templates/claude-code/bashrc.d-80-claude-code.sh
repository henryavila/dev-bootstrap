# shellcheck shell=bash
# ~/.bashrc.d/80-claude-code.sh — puts Bun + Claude Code in PATH.
#
# Why this fragment exists: `curl -fsSL https://bun.sh/install | bash`
# writes the PATH export directly into ~/.bashrc / ~/.zshrc. Our
# managed loader templates overwrite those writes on redeploy — so a
# machine where Bun was installed via a previous bootstrap can end up
# with ~/.bun/bin/bun on disk but NOT on PATH. Observed on crc
# 2026-04-23: bun binary was 103 MB in ~/.bun/bin/, `which bun`
# returned "bun not found". This fragment fixes that by re-asserting
# the PATH at every shell start, gated on file presence.

# Bun runtime
if [ -x "$HOME/.bun/bin/bun" ]; then
    export BUN_INSTALL="$HOME/.bun"
    case ":$PATH:" in *":$BUN_INSTALL/bin:"*) ;; *) export PATH="$BUN_INSTALL/bin:$PATH";; esac
fi

# Claude Code CLI — the official installer drops the binary at
# ~/.local/bin/claude. Ensure that dir is on PATH without duplicating
# if already there.
if [ -x "$HOME/.local/bin/claude" ]; then
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac
fi
