#!/usr/bin/env bash
# Custom installer: shell bootstrap (C14 — generic shell logic moved from
# identity to workstation).
#
# Three side-effects bundled because they share a setup story for users:
#   1. Prepare ~/.bashrc.d, ~/.zshrc.d, ~/.config, ~/.local/bin
#   2. Symlink shell-files/{auto-update,mesh-guard}.zsh → ~/.zshrc.d/
#   3. Copy shell-files/gitignore_global → ~/.gitignore_global +
#      register as git core.excludesfile
#
# Symlinks (not copies) for the zsh hooks so `mesh update -o bootstrap -f`
# updates the source in workstation and the symlink stays valid. The
# gitignore is copied (not symlinked) so `git status` outside of workstation
# doesn't follow into the workstation tree.

check() {
    local here src dst hooks_ok=1
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for shellfile in auto-update.zsh mesh-guard.zsh; do
        src="$here/shell-files/$shellfile"
        dst="$HOME/.zshrc.d/$shellfile"
        if [[ ! -L "$dst" ]] || [[ "$(readlink "$dst")" != "$src" ]]; then
            hooks_ok=0
            break
        fi
    done
    [[ "$hooks_ok" -eq 1 ]] || return 1
    [[ -f "$HOME/.gitignore_global" ]] \
        && cmp -s "$here/shell-files/gitignore_global" "$HOME/.gitignore_global"
}

install() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    mkdir -p "$HOME/.bashrc.d" "$HOME/.zshrc.d" "$HOME/.config" "$HOME/.local/bin"

    # Shell-file symlinks
    for shellfile in auto-update.zsh mesh-guard.zsh; do
        local src="$here/shell-files/$shellfile"
        local dst="$HOME/.zshrc.d/$shellfile"
        if [[ ! -L "$dst" ]] || [[ "$(readlink "$dst")" != "$src" ]]; then
            ln -sf "$src" "$dst"
        fi
    done

    # gitignore_global with backup-on-replace
    local gi_src="$here/shell-files/gitignore_global"
    local gi_dst="$HOME/.gitignore_global"
    if [[ ! -f "$gi_dst" ]] || ! cmp -s "$gi_src" "$gi_dst"; then
        if [[ -f "$gi_dst" ]]; then
            cp -p "$gi_dst" "${gi_dst}.bak-$(date +%Y%m%d-%H%M%S)"
        fi
        cp "$gi_src" "$gi_dst"
    fi

    # Register as git core.excludesfile
    if command -v git >/dev/null 2>&1; then
        local current
        current="$(git config --global --get core.excludesfile 2>/dev/null || true)"
        if [[ "$current" != "$gi_dst" ]]; then
            git config --global core.excludesfile "$gi_dst"
        fi
    fi
}

verify() {
    check
}

rollback() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # Remove the 2 zsh-hook symlinks if they point at our sources.
    for shellfile in auto-update.zsh mesh-guard.zsh; do
        local dst="$HOME/.zshrc.d/$shellfile"
        if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$here/shell-files/$shellfile" ]]; then
            rm -f "$dst"
        fi
    done
    # gitignore_global: don't remove (user may have edited / git config may still reference)
}
