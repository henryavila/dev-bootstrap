# shellcheck shell=bash

cmd_upgrade_run() {
    local runner
    runner="$(_resolve_companion "runners/upgrade.sh")"
    [[ -n "$runner" ]] || _die "runners/upgrade.sh not found (set \$MESH_HOME or check installation)"
    export MESH_AUTOUPDATE_ALIAS="${MESH_AUTOUPDATE_ALIAS:-$(_mesh_self_alias)}"
    exec bash "$runner" "$@"
}

mesh_register_command \
    --name upgrade \
    --summary "Upgrade autoupdate-flagged packages" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_upgrade_run
