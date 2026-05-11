#!/usr/bin/env bash
# Verify code-server standalone + LaunchAgent state.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

: "${CODE_SERVER_PORT:=8080}"
: "${CODE_SERVER_LABEL:=com.${USER}.code-server}"

config_file="$HOME/.config/code-server/config.yaml"
code_server_bin="$HOME/.local/bin/code-server"

"$code_server_bin" --version >/dev/null
ok "code-server binary works at $code_server_bin"

[[ -f "$config_file" ]] || { fail "missing $config_file"; exit 1; }
mode="$(stat -f '%Lp' "$config_file")"
[[ "$mode" == "600" ]] || { fail "$config_file mode is $mode, want 600"; exit 1; }
ok "$config_file exists with mode 0600"

grep -qxF "bind-addr: 127.0.0.1:${CODE_SERVER_PORT}" "$config_file" \
    || { fail "$config_file does not bind 127.0.0.1:${CODE_SERVER_PORT}"; exit 1; }
ok "config binds to 127.0.0.1:${CODE_SERVER_PORT}"

grep -Eq '^[[:space:]]*auth:[[:space:]]*password[[:space:]]*$' "$config_file" \
    || { fail "$config_file does not enforce auth: password"; exit 1; }
ok "config enforces auth: password"

launchctl print "gui/$(id -u)/${CODE_SERVER_LABEL}" >/dev/null
ok "LaunchAgent ${CODE_SERVER_LABEL} is loaded"

curl -fsS --max-time 2 "http://127.0.0.1:${CODE_SERVER_PORT}/healthz" >/dev/null
ok "healthz responds on 127.0.0.1:${CODE_SERVER_PORT}"

listeners="$(lsof -nP -iTCP:"$CODE_SERVER_PORT" -sTCP:LISTEN 2>/dev/null || true)"
[[ -n "$listeners" ]] || { fail "no listener found on TCP:${CODE_SERVER_PORT}"; exit 1; }
if printf '%s\n' "$listeners" | awk -v port="$CODE_SERVER_PORT" '
    NR == 1 { next }
    $0 !~ ("TCP 127\\.0\\.0\\.1:" port " \\(LISTEN\\)$") { bad=1 }
    END { exit bad ? 0 : 1 }
'; then
    printf '%s\n' "$listeners" >&2
    fail "code-server is not loopback-only on 127.0.0.1:${CODE_SERVER_PORT}"
    exit 1
fi
ok "listener is loopback-only on 127.0.0.1:${CODE_SERVER_PORT}"

if [[ "${CODE_SERVER_TAILSCALE_SERVE:-0}" == "1" ]]; then
    tailscale serve status 2>/dev/null | grep -q "127.0.0.1:${CODE_SERVER_PORT}" \
        || { fail "Tailscale Serve status does not mention 127.0.0.1:${CODE_SERVER_PORT}"; exit 1; }
    ok "Tailscale Serve mentions 127.0.0.1:${CODE_SERVER_PORT}"
fi
