# shellcheck shell=bash
# ~/.zshrc.d/00-dev-bootstrap-env.sh — global dev-bootstrap feature defaults.

# Hard kill switch for dormant auto-main. This fragment loads before
# ~/.zshrc.d/40-tmux.sh, including older deployed copies whose own default was
# opt-out instead of opt-in.
export DEV_BOOTSTRAP_TMUX_AUTO_MAIN=0

# MESH_WORKSTATION_DIR auto-derived from the ~/.local/bin/mesh symlink that
# setup.sh creates (C13.5). Lets ~/.zshrc.d/auto-update.zsh + mesh-guard.zsh
# find the workstation root without needing each user to set the env var
# manually. Honors a pre-set value (env override wins). See Review B
# finding B2.
# Load per-host config (~/.config/mesh/config.env) when neither mesh dir is
# set yet. The config file is shell-sourceable (key=value lines) and may set
# MESH_WORKSTATION_DIR, MESH_IDENTITY_DIR, AUTO_UPDATE_REPOS, etc.
if [[ -z "${MESH_WORKSTATION_DIR:-}" && -z "${MESH_IDENTITY_DIR:-}" ]]; then
    [[ -r "$HOME/.config/mesh/config.env" ]] && . "$HOME/.config/mesh/config.env"
fi

# MESH_WORKSTATION_DIR auto-derived from the ~/.local/bin/mesh symlink that
# setup.sh creates (C13.5). Honors a pre-set value (env or config.env wins).
if [[ -z "${MESH_WORKSTATION_DIR:-}" ]] && [[ -L "$HOME/.local/bin/mesh" ]]; then
    _mesh_link=$(readlink "$HOME/.local/bin/mesh")
    case "$_mesh_link" in
        */bin/mesh) export MESH_WORKSTATION_DIR="${_mesh_link%/bin/mesh}" ;;
    esac
    unset _mesh_link
fi

: "${MESH_IDENTITY_DIR:=$HOME/mesh-identity}"
: "${DOTFILES_DIR:=$MESH_IDENTITY_DIR}"
export MESH_WORKSTATION_DIR MESH_IDENTITY_DIR DOTFILES_DIR
