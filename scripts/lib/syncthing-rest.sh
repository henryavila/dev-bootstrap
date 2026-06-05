#!/usr/bin/env bash
# syncthing-rest.sh — bash side of the `mesh syncthing` mechanism (engine layer).
#
# Owns the parts that are OS-specific and live OUTSIDE the daemon's REST surface:
#   - locating config.xml (mac / WSL / Linux candidate paths)
#   - extracting the API key + deriving the reachable REST base from config.xml
#     (so we talk to wherever the GUI is *actually* bound — 0.0.0.0/local/tailscale)
#   - ensuring the daemon is running (best-effort start; in the apply phase the
#     syncthing-service item has already started it)
#
# Everything JSON/REST/YAML is delegated to the dependency-free python sidecar
# scripts/lib/syncthing-rest.py (urllib + a YAML-subset reader — no PyYAML, no
# jq). This file is SOURCED by scripts/runners/syncthing.sh; it sets no `set -e`
# of its own (the engine controls that) and exports nothing globally except the
# documented ST_* result vars.
#
# Public surface (proposal §4.1):
#   st_config_path                 → echo the in-use config.xml (rc1 if none)
#   st_apikey [cfg]                → echo the REST API key
#   st_rest_base [cfg]             → echo the reachable REST base URL
#   st_daemon_running              → rc0 if the daemon answers / is up
#   st_start_daemon                → best-effort OS-aware start
#   st_wait_ready [base] [apikey]  → poll /rest/system/ping until ready (rc1 on timeout)
#   st_ensure_ready                → config+apikey+base+running+ready; sets ST_CFG/ST_APIKEY/ST_BASE
#   st_py <args...>                → invoke the python sidecar with MESH_ST_BASE/APIKEY set
#   st_myid / st_pair / st_status / st_reset_password / st_init_hub

_ST_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd -P)"

# Resolve the python sidecar through a fallback chain: the sourced lib dir is the
# happy path, but $MESH_WORKSTATION_DIR (the engine's canonical env, exported by
# bin/mesh + env.sh) and $MESH_HOME make it robust when BASH_SOURCE is unreliable.
_st_pyfile() {
    local c
    for c in \
        "$_ST_LIB_DIR/syncthing-rest.py" \
        "${MESH_WORKSTATION_DIR:-}/scripts/lib/syncthing-rest.py" \
        "${MESH_HOME:-}/lib/syncthing-rest.py"; do
        [[ -n "$c" && -f "$c" ]] && { printf '%s\n' "$c"; return 0; }
    done
    echo "syncthing: syncthing-rest.py not found (set MESH_WORKSTATION_DIR)" >&2
    return 1
}

# ─── config.xml location (OS-aware; mirrors join-mesh.sh) ───
st_config_path() {
    local os candidates=() p
    os="$(uname -s)"
    case "$os" in
        Linux)
            candidates=(
                "$HOME/.local/state/syncthing/config.xml"
                "$HOME/.config/syncthing/config.xml"
            ) ;;
        Darwin)
            candidates=(
                "$HOME/.local/state/syncthing/config.xml"
                "$HOME/Library/Application Support/Syncthing/config.xml"
            ) ;;
        *)
            candidates=( "$HOME/.local/state/syncthing/config.xml" ) ;;
    esac
    for p in "${candidates[@]}"; do
        [[ -f "$p" ]] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

st_apikey() {
    local cfg="${1:-}"
    [[ -n "$cfg" ]] || cfg="$(st_config_path)" || return 1
    local key
    key="$(grep -Eo '<apikey>[^<]+' "$cfg" 2>/dev/null | sed 's/<apikey>//' | head -1)"
    [[ -n "$key" ]] && { printf '%s\n' "$key"; return 0; }
    return 1
}

# Derive a REST base we can actually reach from the gui.address in config.xml.
# 0.0.0.0 / unspecified host → 127.0.0.1 (loopback is in 0.0.0.0); an explicit
# IP (e.g. a Tailscale 100.x) is reachable locally so we use it verbatim.
st_rest_base() {
    local cfg="${1:-}"
    [[ -n "$cfg" ]] || cfg="$(st_config_path)" || { printf 'http://127.0.0.1:8384\n'; return 0; }
    local addr scheme=http host port
    # The gui block carries its OWN <address>; device blocks also have <address>
    # (often "dynamic"), so scope the extraction to <gui>…</gui>.
    # <gui enabled="true" tls="false">…<address>0.0.0.0:8384</address>
    grep -Eq '<gui[^>]*tls="true"' "$cfg" 2>/dev/null && scheme=https
    addr="$(sed -n '/<gui[ >]/,/<\/gui>/p' "$cfg" 2>/dev/null \
            | grep -Eo '<address>[^<]+' | sed 's/<address>//' | head -1)"
    [[ -n "$addr" ]] || { printf 'http://127.0.0.1:8384\n'; return 0; }
    host="${addr%:*}"; port="${addr##*:}"
    [[ "$port" =~ ^[0-9]+$ ]] || port=8384
    case "$host" in
        ""|0.0.0.0|::|"[::]") host=127.0.0.1 ;;
    esac
    printf '%s://%s:%s\n' "$scheme" "$host" "$port"
}

st_daemon_running() {
    local base="${1:-$(st_rest_base)}"
    curl -sf -o /dev/null --max-time 2 "$base" 2>/dev/null && return 0
    pgrep -u "$USER" -f 'syncthing' >/dev/null 2>&1
}

# Best-effort start. In the apply phase the syncthing-service item already did
# this; standalone `mesh syncthing` calls may need it if the user stopped it.
st_start_daemon() {
    st_daemon_running && return 0
    local os; os="$(uname -s)"
    case "$os" in
        Linux)
            if systemctl --user list-unit-files syncthing.service >/dev/null 2>&1; then
                systemctl --user start syncthing.service 2>/dev/null || true
            else
                ( syncthing serve --no-browser --no-restart >/tmp/mesh-syncthing.log 2>&1 & )
            fi ;;
        Darwin)
            if launchctl print "gui/$(id -u)/com.${USER}.syncthing" >/dev/null 2>&1; then
                launchctl kickstart "gui/$(id -u)/com.${USER}.syncthing" 2>/dev/null || true
            elif command -v brew >/dev/null 2>&1; then
                "${BREW_BIN:-brew}" services start syncthing 2>/dev/null || true
            else
                ( syncthing --no-browser --no-restart >/tmp/mesh-syncthing.log 2>&1 & )
            fi ;;
    esac
    local _ ; for _ in $(seq 1 15); do st_daemon_running && return 0; sleep 1; done
    return 1
}

st_wait_ready() {
    local base="${1:-$(st_rest_base)}" key="${2:-$(st_apikey)}" _
    for _ in $(seq 1 20); do
        if curl -sf -o /dev/null --max-time 2 -H "X-API-Key: $key" "$base/rest/system/ping" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# Resolve everything once; sets ST_CFG / ST_APIKEY / ST_BASE for the caller.
st_ensure_ready() {
    ST_CFG="$(st_config_path)" || { echo "syncthing: config.xml not found — is Syncthing installed/started?" >&2; return 1; }
    ST_APIKEY="$(st_apikey "$ST_CFG")" || { echo "syncthing: could not read API key from $ST_CFG" >&2; return 1; }
    ST_BASE="$(st_rest_base "$ST_CFG")"
    if ! st_daemon_running "$ST_BASE"; then
        st_start_daemon || { echo "syncthing: daemon not running and could not be started" >&2; return 1; }
        ST_BASE="$(st_rest_base "$ST_CFG")"
    fi
    st_wait_ready "$ST_BASE" "$ST_APIKEY" || { echo "syncthing: REST API not responding on $ST_BASE" >&2; return 1; }
    export ST_CFG ST_APIKEY ST_BASE
    return 0
}

# Thin wrapper: run the python sidecar with the REST env wired up.
st_py() {
    local py; py="$(_st_pyfile)" || return 1
    MESH_ST_BASE="${ST_BASE:-$(st_rest_base)}" \
    MESH_ST_APIKEY="${ST_APIKEY:-$(st_apikey)}" \
        python3 "$py" "$@"
}

st_myid()           { st_py myid; }
st_pair()           { st_py pair "$@"; }
st_status()         { st_py status "$@"; }
st_reset_password() { st_py reset-password "$@"; }
st_init_hub()       { st_py init-hub "$@"; }
