#!/usr/bin/env bash
# C15: 5 shipped default configs (p10k, btop, btop theme, eza, htop).
# Identity overrides win on conflict (95-dotfiles-personal MAPPINGS run later).

_pairs() {
    cat <<'EOF'
configs/p10k.zsh|$HOME/.p10k.zsh
configs/btop/btop.conf|$HOME/.config/btop/btop.conf
configs/btop/themes/catppuccin_mocha.theme|$HOME/.config/btop/themes/catppuccin_mocha.theme
configs/eza/theme.yml|$HOME/.config/eza/theme.yml
configs/htoprc|$HOME/.config/htop/htoprc
EOF
}

check() {
    local here src dst rel
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    while IFS='|' read -r rel dst; do
        [[ -z "$rel" ]] && continue
        src="$here/$rel"
        dst="$(eval echo "$dst")"
        # Either correct symlink, OR identity wins (existing real file)
        if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$src" ]]; then continue; fi
        if [[ -f "$dst" ]] && [[ ! -L "$dst" ]]; then continue; fi
        return 1
    done < <(_pairs)
    return 0
}

install() {
    local here ws_lib
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ws_lib="${MESH_WORKSTATION_DIR:-$(cd "$here/../.." && pwd)}/scripts/lib"
    # shellcheck disable=SC1091
    . "$ws_lib/topic-configs.sh"
    local rel dst
    while IFS='|' read -r rel dst; do
        [[ -z "$rel" ]] && continue
        dst="$(eval echo "$dst")"
        link_default_config "$here/$rel" "$dst"
    done < <(_pairs)
}

verify() {
    check
}

rollback() {
    local here src dst rel
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    while IFS='|' read -r rel dst; do
        [[ -z "$rel" ]] && continue
        src="$here/$rel"
        dst="$(eval echo "$dst")"
        if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$src" ]]; then
            rm -f "$dst"
        fi
    done < <(_pairs)
}
