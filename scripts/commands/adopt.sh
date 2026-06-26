# shellcheck shell=bash

cmd_adopt_run() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                cat <<'EOF'
Usage:
  mesh adopt     Read-only: for every tool already installed but missing its
                 mesh install marker (e.g. a machine set up by the older v1
                 system), write the marker WITHOUT running any install/deploy/
                 sudo. Makes the setup menu show the true install state.
                 Idempotent + safe to re-run; an absent tool gets no marker.
EOF
                return 0 ;;
            *) _die "adopt: unexpected arg '$1' (mesh adopt takes no arguments)" ;;
        esac
    done
    local repo
    repo="$(_resolve_workstation_repo)" || \
        _die "mesh-workstation repo not found (set MESH_WORKSTATION_DIR) -- needed for adopt"
    exec bash "$repo/setup.sh" --adopt
}

sub_adopt() {
    cmd_adopt_run "$@"
}

mesh_register_command \
    --name adopt \
    --summary "Backfill install markers read-only" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_adopt_run
