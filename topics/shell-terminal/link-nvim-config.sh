#!/usr/bin/env bash
# Custom installer: links the topic's nvim default init.lua to
# ~/.config/nvim/init.lua via link_default_config. Identity files in
# mesh-identity win on conflict (existing real file or matching symlink
# → no-op); else symlink.
#
# The link target lives at $HERE/configs/nvim/init.lua. Engine sources
# this file inside a subshell with helpers pre-sourced, but it does NOT
# inherit our $HERE — the script computes it itself via $(dirname "${BASH_SOURCE[0]}").

check() {
    local dst
    dst="$HOME/.config/nvim/init.lua"
    # Aligned with link_default_config "first-writer-wins": any existing
    # destination (real file, our symlink, identity-shipped foreign
    # symlink — stow-style workflows) counts as satisfied.
    # CP4 chunk C finding C-F-001.
    [[ -e "$dst" ]] || [[ -L "$dst" ]] || return 1
    return 0
}

install() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck disable=SC1091
    . "$here/../../scripts/lib/topic-configs.sh"
    mkdir -p "$HOME/.local/bin"   # legacy: kept so typora-wait wrappers find a writable target
    link_default_config "$here/configs/nvim/init.lua" "$HOME/.config/nvim/init.lua"
}

verify() {
    check
}

repair() { install; }

rollback() {
    local here dst
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    dst="$HOME/.config/nvim/init.lua"
    # Only remove if it's OUR symlink (don't touch identity's real file)
    if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$here/configs/nvim/init.lua" ]]; then
        rm -f "$dst"
    fi
}
