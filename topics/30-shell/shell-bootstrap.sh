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
        # CP4 chunk C finding C-F-003: require source to exist AND the
        # dst symlink to point at it. Previous version accepted a
        # dangling symlink as "healthy" after the source file was
        # removed (branch swap / partial sync / sparse checkout).
        if [[ ! -f "$src" ]] || [[ ! -L "$dst" ]] || \
           [[ "$(readlink "$dst")" != "$src" ]]; then
            hooks_ok=0
            break
        fi
    done
    [[ "$hooks_ok" -eq 1 ]] || return 1
    [[ -f "$HOME/.gitignore_global" ]] \
        && cmp -s "$here/shell-files/gitignore_global" "$HOME/.gitignore_global"
}

install() {
    local here ws_lib
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ws_lib="${MESH_WORKSTATION_DIR:-$(cd "$here/../.." && pwd)}/scripts/lib"
    # Source unique_backup_path helper (also brings link_default_config,
    # not used here but harmless).
    # shellcheck disable=SC1091
    . "$ws_lib/topic-configs.sh"

    mkdir -p "$HOME/.bashrc.d" "$HOME/.zshrc.d" "$HOME/.config" "$HOME/.local/bin"

    # Shell-file symlinks. CP4 chunk C finding C-F-003: refuse to
    # create dangling links — fail loud if a required hook source is
    # missing (partial workstation checkout).
    for shellfile in auto-update.zsh mesh-guard.zsh; do
        local src="$here/shell-files/$shellfile"
        local dst="$HOME/.zshrc.d/$shellfile"
        if [[ ! -f "$src" ]]; then
            warn "30-shell: required hook source missing: $src"
            return 1
        fi
        if [[ ! -L "$dst" ]] || [[ "$(readlink "$dst")" != "$src" ]]; then
            ln -sf "$src" "$dst"
        fi
    done

    # gitignore_global with collision-safe backup-on-replace.
    # CP4 chunk C finding C-F-005: previously `.bak-$(date +%Y%m%d-%H%M%S)`
    # silently overwrote the only backup when two reruns landed in the
    # same second. unique_backup_path appends a counter on collision.
    local gi_src="$here/shell-files/gitignore_global"
    local gi_dst="$HOME/.gitignore_global"
    if [[ ! -f "$gi_dst" ]] || ! cmp -s "$gi_src" "$gi_dst"; then
        if [[ -f "$gi_dst" ]]; then
            cp -p "$gi_dst" "$(unique_backup_path "$gi_dst")"
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
