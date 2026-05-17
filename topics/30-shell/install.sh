#!/usr/bin/env bash
# 30-shell: modular bashrc/zshrc loader (OS-agnostic).
# Ensures ~/.bashrc.d and ~/.zshrc.d directories exist; templates do the rest.
# Plus: deploys generic shell hooks (auto-update.zsh + mesh-guard.zsh) and
# the global gitignore from shell-files/ (C14 — generic shell logic moved
# from identity to workstation).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/log.sh"

mkdir -p "$HOME/.bashrc.d" "$HOME/.zshrc.d" "$HOME/.config" "$HOME/.local/bin"

# ─── C14: deploy generic shell hooks ────────────────────────────────────
# auto-update.zsh + mesh-guard.zsh both target zsh; symlink (not copy) so
# `auto-update -o bootstrap -f` updates the source in workstation and the
# symlink stays valid. mesh-guard reads MESH_IDENTITY_DIR for repo list +
# redirect target; auto-update points at workstation's runners/auto-update.sh.
for shellfile in auto-update.zsh mesh-guard.zsh; do
    src="$HERE/shell-files/$shellfile"
    dst="$HOME/.zshrc.d/$shellfile"
    if [[ ! -L "$dst" ]] || [[ "$(readlink "$dst")" != "$src" ]]; then
        ln -sf "$src" "$dst"
        ok "deployed $shellfile → $dst (symlink)"
    fi
done

# gitignore_global → ~/.gitignore_global + register as core.excludesfile.
# Copy (not symlink) so the user's git client doesn't follow into the
# workstation tree if they `git status` outside of it.
gitignore_src="$HERE/shell-files/gitignore_global"
gitignore_dst="$HOME/.gitignore_global"
if [[ ! -f "$gitignore_dst" ]] || ! cmp -s "$gitignore_src" "$gitignore_dst"; then
    if [[ -f "$gitignore_dst" ]]; then
        cp -p "$gitignore_dst" "${gitignore_dst}.bak-$(date +%Y%m%d-%H%M%S)"
    fi
    cp "$gitignore_src" "$gitignore_dst"
    ok "deployed gitignore_global → $gitignore_dst"
fi
if command -v git >/dev/null 2>&1; then
    current="$(git config --global --get core.excludesfile 2>/dev/null || true)"
    if [[ "$current" != "$gitignore_dst" ]]; then
        git config --global core.excludesfile "$gitignore_dst"
        ok "registered $gitignore_dst as git core.excludesfile"
    fi
fi

ok "30-shell directories prepared + shell hooks deployed"
