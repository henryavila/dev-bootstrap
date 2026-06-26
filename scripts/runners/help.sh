#!/usr/bin/env bash
# scripts/runners/help.sh — interactive help browser for mesh commands.
#
# Usage:
#   mesh help [command]          Open the blink help browser (TTY only).
#   mesh help --plain           Print compact top-level help.
#   mesh help <command> --plain  Print `mesh <command> --help`.
#   mesh help -h|--help         Show this usage text.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MESH_BIN="$ROOT/bin/mesh"

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }

plain=0
selected=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --plain) plain=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*)
            printf 'mesh help: unknown flag %s\n' "$1" >&2
            exit 2
            ;;
        *)
            if [[ -n "$selected" ]]; then
                printf 'mesh help: expected at most one command, got %s and %s\n' "$selected" "$1" >&2
                exit 2
            fi
            selected="$1"
            shift
            ;;
    esac
done

if (( plain )); then
    if [[ -n "$selected" ]]; then
        MESH_HELP_PLAIN=1 "$MESH_BIN" "$selected" --help
    else
        MESH_HELP_PLAIN=1 "$MESH_BIN" --help
    fi
    exit $?
fi

if [[ "${MESH_HELP_PICKER:-}" == "plain" || ! -t 0 || ! -t 1 ]]; then
    if [[ -n "$selected" ]]; then
        MESH_HELP_PLAIN=1 "$MESH_BIN" "$selected" --help
    else
        MESH_HELP_PLAIN=1 "$MESH_BIN" --help
    fi
    exit $?
fi

if ! command -v node >/dev/null 2>&1; then
    MESH_HELP_PLAIN=1 "$MESH_BIN" --help
    exit $?
fi

MENU="$ROOT/scripts/menu/index.js"
if [[ ! -f "$MENU" ]]; then
    MESH_HELP_PLAIN=1 "$MESH_BIN" --help
    exit $?
fi

tmp="$(mktemp -d -t mesh-help.XXXXXX)" || exit 1
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

commands="$tmp/commands.tsv"
details="$tmp/details"
mkdir -p "$details"

if ! MESH_HELP_PLAIN=1 "$MESH_BIN" __commands > "$commands"; then
    exit $?
fi

while IFS=$'\t' read -r name _summary _group _origin _visibility _fanout; do
    [[ -n "$name" ]] || continue
    if MESH_HELP_PLAIN=1 NON_INTERACTIVE=1 "$MESH_BIN" "$name" --help > "$details/$name" 2>&1 </dev/null; then
        :
    else
        rc=$?
        {
            printf 'mesh %s --help exited with rc %s\n' "$name" "$rc"
            printf '\n'
            cat "$details/$name" 2>/dev/null || true
        } > "$details/$name.tmp"
        mv "$details/$name.tmp" "$details/$name"
    fi
done < "$commands"

node_args=(help --commands "$commands" --details-dir "$details")
[[ -n "$selected" ]] && node_args+=(--selected "$selected")
node "$MENU" "${node_args[@]}" </dev/tty >/dev/tty
rc=$?
case "$rc" in
    0|130) exit 0 ;;
    *) MESH_HELP_PLAIN=1 "$MESH_BIN" --help; exit $? ;;
esac
