# shellcheck shell=bash

cmd_menu_run() {
    local runner apply=0
    runner="$(_resolve_companion "runners/menu.sh")"
    [[ -n "$runner" ]] || _die "runners/menu.sh not found (set \$MESH_HOME or check installation)"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --apply) apply=1; shift ;;
            -h|--help)
                echo "Usage: mesh menu [--apply]"
                echo "  mesh menu          Run the interactive selector (standalone)"
                echo "  mesh menu --apply  Run selector + execute install/uninstall delta"
                return 0 ;;
            *) _die "menu: unknown arg '$1'" ;;
        esac
    done
    if (( apply )); then
        exec bash "$runner" --apply
    else
        exec bash "$runner"
    fi
}

mesh_register_command \
    --name menu \
    --summary "Open the interactive item selector" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_menu_run
