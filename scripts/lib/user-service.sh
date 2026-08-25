#!/usr/bin/env bash
# lib/user-service.sh — systemd user-service manager for Linux/WSL.
#
# Counterpart of launch-wrapper.sh (macOS TCC workaround). Provides a
# uniform API for installing, checking, and tearing down user-scope
# daemons on Linux, with automatic detection of systemd availability.
#
# Source from a topic; do not execute directly.
# On macOS, all public functions noop and return 0.
#
# Public API:
#   user_service_install --name NAME --exec PATH [--args "..."] \
#       [--description "..."] [--after TARGET]
#   user_service_teardown NAME
#   user_service_is_running NAME
#   user_service_has_systemd          (0 if usable, 1 otherwise)

[ -n "${_USER_SERVICE_LOADED:-}" ] && return 0
_USER_SERVICE_LOADED=1

_US_SVC_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

user_service_has_systemd() {
    [[ "$(uname -s)" == "Linux" ]] || return 1
    systemctl --user is-system-running >/dev/null 2>&1
}

user_service_is_running() {
    local name="$1"
    if user_service_has_systemd; then
        systemctl --user is-active "${name}.service" >/dev/null 2>&1
    else
        pgrep -u "$USER" -f "$name" >/dev/null 2>&1
    fi
}

user_service_install() {
    [[ "$(uname -s)" == "Linux" ]] || return 0

    local name="" exec_path="" args="" description="" after="network.target"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)        name="$2"; shift 2 ;;
            --exec)        exec_path="$2"; shift 2 ;;
            --args)        args="$2"; shift 2 ;;
            --description) description="$2"; shift 2 ;;
            --after)       after="$2"; shift 2 ;;
            *) printf 'user_service_install: unknown arg: %s\n' "$1" >&2; return 1 ;;
        esac
    done

    if [[ -z "$name" || -z "$exec_path" ]]; then
        printf 'user_service_install: --name and --exec are required\n' >&2
        return 1
    fi
    : "${description:=$name daemon}"

    local exec_line="$exec_path"
    [[ -n "$args" ]] && exec_line="$exec_path $args"

    if user_service_has_systemd; then
        mkdir -p "$_US_SVC_DIR"
        local unit_file="$_US_SVC_DIR/${name}.service"

        cat > "$unit_file" <<UNIT
[Unit]
Description=${description}
After=${after}

[Service]
Type=simple
ExecStart=${exec_line}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
UNIT

        if command -v loginctl >/dev/null 2>&1; then
            if ! loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
                sudo loginctl enable-linger "$USER" 2>/dev/null || true
            fi
        fi

        systemctl --user daemon-reload 2>/dev/null
        systemctl --user enable --now "${name}.service" 2>/dev/null
    else
        printf '[%s] systemd --user not available — starting via nohup (will not survive WSL restart)\n' "$name" >&2
        # stdin too: a leftover tty/pipe keeps `bash install-engine | tee` from
        # seeing EOF after the engine prints "applied".
        nohup $exec_line </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true
    fi
}

user_service_teardown() {
    local name="$1"
    [[ "$(uname -s)" == "Linux" ]] || return 0

    if user_service_has_systemd; then
        systemctl --user disable --now "${name}.service" 2>/dev/null || true
        rm -f "$_US_SVC_DIR/${name}.service"
        systemctl --user daemon-reload 2>/dev/null || true
    else
        pkill -u "$USER" -f "$name" 2>/dev/null || true
    fi
}
