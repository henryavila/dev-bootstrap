# shellcheck shell=bash

cmd_lint_run() {
    case "${1:-}" in
        -h|--help)
            cat <<'EOF'
Usage: mesh lint

Run repository invariant lints.

Checks:
  scripts/lib/lints/L*.sh

Exit codes:
  0       all lints passed
  1..125  number of failed lints

Notes:
  No output means clean.
EOF
            return 0
            ;;
    esac

    local lib
    lib="$(_resolve_companion "lib/lint.sh")"
    [[ -n "$lib" ]] || _die "lib/lint.sh not found (set \$MESH_HOME or check installation)"
    exec bash "$lib" "$@"
}

mesh_register_command \
    --name lint \
    --summary "Run repo invariant lints" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_lint_run
