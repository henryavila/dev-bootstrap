#!/usr/bin/env bash
# syncthing.sh — operator runner for `mesh syncthing <verb>` (workstation layer).
#
# Orchestrates the engine mechanism (scripts/lib/syncthing-rest.sh + its python
# sidecar) into the user-facing verbs. The MECHANISM (REST, YAML, reconcile)
# lives in the lib; the ORCHESTRATION (which verb, the interactive Tier-0 pause,
# the post-Enter verification loop, banner rendering) lives here.
#
# Verbs:
#   pair               Idempotent reconcile from syncthing-mesh.yaml + real summary.
#                      Pauses ONLY when a genuine first-time hub approval remains
#                      (never under NON_INTERACTIVE / no tty).
#   init-hub [--write] First-hub bootstrap: print this node's id + the ready-to-paste
#                      hubs: block (and append it if --write and hubs: is empty).
#   status             Live convergence summary (peers + folders).
#   password [--reset] Show GUI login state; --reset rotates via the API key and
#                      prints the new password (the only recovery path).
#   url                Print the admin UI URL.
#
# Invoked as `bash scripts/runners/syncthing.sh <verb> [args]`.
set -o pipefail

_RUN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)"
: "${MESH_WORKSTATION_DIR:=$(CDPATH='' cd -- "$_RUN_DIR/.." 2>/dev/null && pwd -P)}"
export MESH_WORKSTATION_DIR

# env.sh resolves MESH_IDENTITY_DIR; the lib carries the st_* surface.
# shellcheck disable=SC1091
. "$MESH_WORKSTATION_DIR/scripts/lib/env.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$MESH_WORKSTATION_DIR/scripts/lib/syncthing-rest.sh"

_die() { printf 'mesh syncthing: %s\n' "$*" >&2; exit 1; }

# ─── data-file resolution (identity = data only) ───
_resolve_data() {
    if [[ -n "${MESH_SYNCTHING_DATA:-}" ]]; then printf '%s\n' "$MESH_SYNCTHING_DATA"; return 0; fi
    local id="${MESH_IDENTITY_DIR:-$HOME/mesh-identity}" c
    for c in "$id/sync/syncthing-mesh.yaml" "$id/claude/sync/syncthing-mesh.yaml"; do
        [[ -f "$c" ]] && { printf '%s\n' "$c"; return 0; }
    done
    printf '%s\n' "$id/sync/syncthing-mesh.yaml"  # canonical default for messages
    return 1
}

_self_name() { printf '%s\n' "${MESH_ST_SELF_NAME:-$(uname -n)}"; }

_interactive() {
    [[ "${NON_INTERACTIVE:-0}" != "1" ]] && [[ -e /dev/tty ]]
}

# ─── verbs ───
verb_pair() {
    local data; data="$(_resolve_data)" || _die "no syncthing-mesh.yaml found (looked under \$MESH_IDENTITY_DIR/sync and /claude/sync; set MESH_SYNCTHING_DATA)"
    st_ensure_ready || exit 1
    local args=(pair --data "$data" --self-name "$(_self_name)")
    [[ "${NON_INTERACTIVE:-0}" = "1" ]] && args+=(--non-interactive)
    local json
    json="$(st_py "${args[@]}")" || exit $?
    printf '%s\n' "$json" | st_py render pair

    local pending; pending="$(printf '%s' "$json" | st_py get pending_approve)"
    if [[ "$pending" = "true" ]] && _interactive; then
        # shellcheck disable=SC2162
        read -p "  Press Enter once you've approved this device on the hub… " _ </dev/tty || true
        _verify_loop "$data"
    elif [[ "$pending" = "true" ]]; then
        echo "  [non-interactive] approve this device on the hub UI later, then re-run \`mesh syncthing pair\`."
    fi
}

# Poll until the hub link is live (or the user gives up). Closes the loop the old
# banner never did.
_verify_loop() {
    local data="$1" i sjson connected
    for i in $(seq 1 10); do
        sjson="$(st_py status --data "$data" 2>/dev/null)" || break
        connected="$(printf '%s' "$sjson" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("yes" if any(p["connected"] for p in d.get("peers",[])) else "no")' 2>/dev/null)"
        if [[ "$connected" = "yes" ]]; then
            echo "  → hub connected ✔"
            printf '%s\n' "$sjson" | st_py render status
            return 0
        fi
        printf '  → still verifying (%d/10)… \r' "$i"
        sleep 3
    done
    echo
    echo "  → not connected yet. The approval may still be propagating — re-run \`mesh syncthing status\` in a minute."
}

verb_init_hub() {
    local data write=0 a
    for a in "$@"; do [[ "$a" = "--write" ]] && write=1; done
    data="$(_resolve_data)" || true
    st_ensure_ready || exit 1
    local args=(init-hub) ; [[ -f "$data" ]] && args+=(--data "$data") ; [[ "$write" = "1" ]] && args+=(--write)
    local json; json="$(st_py "${args[@]}")" || exit $?
    local myid wrote already
    myid="$(printf '%s' "$json" | st_py get myid)"
    wrote="$(printf '%s' "$json" | st_py get wrote)"
    already="$(printf '%s' "$json" | st_py get already_present)"
    echo "  This machine's Syncthing id (the hub id):"
    echo "    $myid"
    if [[ "$already" = "true" ]]; then
        echo "  ✔ already recorded in $data"
    elif [[ "$wrote" = "true" ]]; then
        echo "  ✔ written into $data — commit it so every machine trusts this hub."
    else
        echo
        echo "  Add this to syncthing-mesh.yaml (identity) and commit it:"
        printf '%s' "$json" | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["snippet"])' | sed 's/^/    /'
        [[ -f "$data" ]] && echo "  (or re-run \`mesh syncthing init-hub --write\` to append it for you when hubs: is empty)"
    fi
}

verb_status() {
    local data; data="$(_resolve_data)" || true
    st_ensure_ready || exit 1
    local args=(status); [[ -f "$data" ]] && args+=(--data "$data")
    st_py "${args[@]}" | st_py render status
}

verb_password() {
    local reset=0 a
    for a in "$@"; do
        case "$a" in
            --reset) reset=1 ;;
            --show) echo "  --show is unavailable: the GUI password is bcrypt-hashed and never cached." \
                         "Use --reset to rotate to a fresh, printable password." >&2; exit 2 ;;
        esac
    done
    st_ensure_ready || exit 1
    if [[ "$reset" = "1" ]]; then
        local data; data="$(_resolve_data)" 2>/dev/null || true
        local u="${MESH_ST_GUI_USER:-}"
        if [[ -z "$u" && -f "$data" ]]; then u="$(st_py read-data "$data" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("gui",{}).get("user","") or "")' 2>/dev/null)"; fi
        [[ -n "$u" ]] || u="mesh"
        local res; res="$(st_reset_password --user "$u")" || exit $?
        local pw newuser
        pw="$(printf '%s' "$res" | st_py get password)"
        newuser="$(printf '%s' "$res" | st_py get user)"
        echo "  GUI login reset:  $newuser / $pw"
        echo "  (save it — it is shown only now; the admin UI uses it to log in)"
    else
        echo "  The GUI password is bcrypt-hashed and cannot be displayed."
        echo "  Run \`mesh syncthing password --reset\` to rotate to a fresh, printable one."
    fi
}

verb_url() {
    st_ensure_ready || exit 1
    local base; base="${ST_BASE/0.0.0.0/127.0.0.1}"
    printf '%s\n' "$base"
}

_usage() {
    cat <<'EOF'
Usage:
  mesh syncthing pair               Reconcile this node into the mesh from
                                    syncthing-mesh.yaml + print a real summary.
  mesh syncthing init-hub [--write] First-hub bootstrap: print this node's id
                                    (the hub id) + the hubs: block to commit.
  mesh syncthing status             Live peers + folders convergence summary.
  mesh syncthing password [--reset] Show GUI login state; --reset rotates + prints.
  mesh syncthing url                Print the admin UI URL.

Data file (identity = data only): $MESH_IDENTITY_DIR/sync/syncthing-mesh.yaml
  (override with MESH_SYNCTHING_DATA). The only thing a human edits to add a
  peer, a folder, or a static address.
EOF
}

case "${1:-status}" in
    pair)      shift; verb_pair "$@" ;;
    init-hub)  shift; verb_init_hub "$@" ;;
    status)    shift; verb_status "$@" ;;
    password)  shift; verb_password "$@" ;;
    url)       shift; verb_url "$@" ;;
    -h|--help) _usage ;;
    *)         printf 'mesh syncthing: unknown verb %q\n\n' "$1" >&2; _usage >&2; exit 1 ;;
esac
