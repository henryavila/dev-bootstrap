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
if [[ -z "${MESH_WORKSTATION_DIR:-}" ]] && [[ -L "$HOME/.local/bin/mesh" ]]; then
    _mesh_link=$(readlink "$HOME/.local/bin/mesh")
    case "$_mesh_link" in
        */bin/mesh) export MESH_WORKSTATION_DIR="${_mesh_link%/bin/mesh}" ;;
    esac
    unset _mesh_link
fi
