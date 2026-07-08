# shellcheck shell=bash

cmd_catalog_run() {
    local action="${1:-}"
    case "$action" in
        generate)
            shift
            local lib
            lib="$(_resolve_companion "lib/catalog.sh")"
            [[ -n "$lib" ]] || _die "lib/catalog.sh not found (set \$MESH_HOME or check installation)"
            exec bash "$lib" "$@"
            ;;
        ""|-h|--help)
            cat <<'EOF'
Usage: mesh catalog generate

Regenerates .catalog/ with 4 derived files + index:
  resources.txt   files under topics/*/resources/
  opt-ins.txt     INCLUDE_* env-var toggles
  cli.txt         mesh subcommands (parsed from bin/mesh)
  drivers.txt     installer drivers in scripts/lib/installers/
  README.md       index + pointer to docs/catalog/behaviors.md

Output is byte-stable; CI can diff two runs to detect drift.
EOF
            ;;
        *)
            _die "catalog: unknown action '$action' (try: mesh catalog generate)"
            ;;
    esac
}

mesh_register_command \
    --name catalog \
    --summary "Regenerate derived catalog listings" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_catalog_run
