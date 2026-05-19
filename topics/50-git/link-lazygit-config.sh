#!/usr/bin/env bash
# Custom installer: link lazygit default config (C15).
# Identity (95-dotfiles-personal MAPPINGS) wins on conflict — that topic
# runs AFTER this one.

_src() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    printf '%s\n' "$here/configs/lazygit/config.yml"
}

check() {
    local dst
    dst="$HOME/.config/lazygit/config.yml"
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
    link_default_config "$here/configs/lazygit/config.yml" "$HOME/.config/lazygit/config.yml"
}

verify() {
    check
}

rollback() {
    local src dst
    src="$(_src)"
    dst="$HOME/.config/lazygit/config.yml"
    if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$src" ]]; then
        rm -f "$dst"
    fi
}
