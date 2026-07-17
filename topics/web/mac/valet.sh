#!/usr/bin/env bash
# Custom: Laravel Valet — composer global install + valet install + .localhost TLD + park CODE_DIR.

: "${CODE_DIR:=$HOME/code}"

_VALET_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r "$_VALET_SCRIPT_DIR/launchdaemon-hardening.sh" ]]; then
    # shellcheck disable=SC2034  # consumed by the sourced helper
    MESH_LAUNCHDAEMON_HARDENING_LIB_ONLY=1
    # shellcheck source=/dev/null
    . "$_VALET_SCRIPT_DIR/launchdaemon-hardening.sh"
    unset MESH_LAUNCHDAEMON_HARDENING_LIB_ONLY
fi

# Resolve the valet binary from composer's actual global bin-dir at runtime.
# Composer's home is ~/.composer on older defaults but ~/.config/composer when
# XDG is set or on newer composer — never hard-pin one. Each verb is sourced in
# a fresh subshell, so this runs per verb.
_resolve_valet_bin() {
    local bindir cand
    bindir="$(composer global config --absolute bin-dir 2>/dev/null || true)"
    for cand in "$bindir/valet" \
                "$HOME/.composer/vendor/bin/valet" \
                "$HOME/.config/composer/vendor/bin/valet"; do
        if [[ -n "$cand" && -x "$cand" ]]; then
            VALET_BIN="$cand"
            return 0
        fi
    done
    # Not yet installed: default to composer's reported bin-dir if known,
    # else the legacy ~/.composer path so install() can write/probe it.
    VALET_BIN="${bindir:+$bindir/valet}"
    VALET_BIN="${VALET_BIN:-$HOME/.composer/vendor/bin/valet}"
    return 0
}

# Valet and Composer execute the default PHP CLI. The languages/php owner
# already verifies every declared version, but this boundary probe prevents a
# later local drift from being mislabeled as a LaunchDaemon failure. Any stderr
# is unhealthy — not only one known "PHP Startup" spelling (L-003).
_valet_php_probe_clean() {
    local php_stderr="" php_rc=0
    if ! command -v php >/dev/null 2>&1; then
        echo "[valet] PHP health check failed before Valet repair: php is not on PATH; repair languages/php first" >&2
        return 1
    fi
    php_stderr="$(php -v 2>&1 >/dev/null)" || php_rc=$?
    if [[ "$php_rc" -ne 0 || -n "$php_stderr" ]]; then
        echo "[valet] PHP health check failed before Valet repair (rc=$php_rc); repair languages/php first" >&2
        [[ -n "$php_stderr" ]] && printf '%s\n' "$php_stderr" | sed -n '1,4p' >&2
        return 1
    fi
    return 0
}

_valet_report_install_failure() {
    local output="$1" rc="$2"
    [[ -n "$output" ]] && printf '%s\n' "$output" >&2
    case "$output" in
        *"PHP Startup"*|*"PHP Warning"*|*"Fatal error"*|*"Parse error"*|*Deprecated:*)
            echo "[valet] PHP health failed during Valet activation (rc=$rc); repair languages/php before retrying" >&2
            ;;
        *dyld*|*"Library not loaded"*|*"Operation not permitted"*|*sandbox*|*EX_CONFIG*|*" 78"*)
            echo "[valet] PHP health passed; Valet service activation failed (LaunchDaemon/dyld/sandbox, rc=$rc). Run \`mesh doctor --fix\` and inspect /var/log/homebrew/php.log" >&2
            ;;
        *)
            echo "[valet] PHP health passed; valet install failed (rc=$rc). Run \`mesh doctor --fix\` and inspect the output above" >&2
            ;;
    esac
}

_valet_harden_launchdaemons() {
    declare -f launchdaemon_harden_install >/dev/null 2>&1 || return 0
    local rc=0
    launchdaemon_harden_install || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "[valet] PHP health passed; LaunchDaemon hardening/activation failed. Run \`mesh doctor --fix\` after reviewing the diagnostic above" >&2
        return "$rc"
    fi
}

_valet_launchdaemon_running() {
    local svc="$1" launchctl_bin="${MESH_LAUNCHCTL_BIN:-launchctl}" state_out=""
    state_out="$("$launchctl_bin" print "system/homebrew.mxcl.${svc}" 2>/dev/null)" || return 1
    [[ "$state_out" == *"state = running"* ]]
}

# Is CODE_DIR on an external /Volumes/<vol> that is NOT currently mounted?
# When true, valet has nothing to serve yet, so repair must DEFER: do not fail
# check(), and do NOT `mkdir -p` a phantom /Volumes/... on the root disk that
# would later collide with the real mount point (verify/operational plan D-3).
_valet_external_unmounted() {
    case "${CODE_DIR:-}" in
        /Volumes/*) ;;
        *) return 1 ;;                              # not on an external volume
    esac
    local rest vol
    rest="${CODE_DIR#/Volumes/}"
    vol="${rest%%/*}"
    [[ -n "$vol" ]] || return 1
    # Mounted iff `mount` lists "... on /Volumes/<vol> (". A leftover/phantom
    # directory is NOT a mount, so this distinguishes "volume present" from it.
    mount 2>/dev/null | grep -qF " on /Volumes/$vol (" && return 1
    return 0                                        # configured external path, not mounted
}

# A socket inode alone is not an operational php-fpm boundary: regular files,
# broken symlinks, stale sockets, and bound-but-not-listening AF_UNIX sockets
# must all remain red. Connect with a short timeout and close immediately. This
# is deliberately sudo-free so check()/menu scans never prompt for credentials.
_valet_unix_socket_accepting() {
    local socket_path="$1"
    [[ -S "$socket_path" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$socket_path" "${VALET_SOCKET_CONNECT_TIMEOUT:-0.25}" <<'PY'
import socket
import sys

path = sys.argv[1]
try:
    timeout = float(sys.argv[2])
except (TypeError, ValueError):
    timeout = 0.25
if timeout <= 0 or timeout > 2:
    timeout = 0.25

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(timeout)
try:
    client.connect(path)
except (OSError, socket.timeout):
    raise SystemExit(1)
finally:
    client.close()
PY
}

# Sudo-free operational probe: are all three valet daemons actually serving?
# The valet CLI shells out to sudo (and the menu scanner stubs sudo), so we
# probe the live stack directly instead of asking the CLI — TCP for nginx, a
# direct dnsmasq query for DNS, and the php-fpm socket. Any miss ⇒ stack down.
_valet_stack_ok() {
    VALET_STACK_FAILURE=""
    # A stale socket can survive a dyld crash, so prove the supervised php-fpm
    # job itself is running before trusting the filesystem marker.
    if ! _valet_launchdaemon_running php; then
        VALET_STACK_FAILURE="php-fpm"
        return 1
    fi
    if ! _valet_unix_socket_accepting "$HOME/.config/valet/valet.sock"; then
        VALET_STACK_FAILURE="php-fpm"
        return 1
    fi
    if ! _valet_launchdaemon_running nginx; then
        VALET_STACK_FAILURE="nginx"
        return 1
    fi
    # nginx listening on :80 (bash /dev/tcp; the subshell closes the fd on exit)
    if ! (exec 3<>/dev/tcp/127.0.0.1/80) 2>/dev/null; then
        VALET_STACK_FAILURE="nginx"
        return 1
    fi
    if ! _valet_launchdaemon_running dnsmasq; then
        VALET_STACK_FAILURE="dnsmasq"
        return 1
    fi
    # dnsmasq answers *.localhost on 127.0.0.1. Require a real answer, not just
    # rc 0 — dscacheutil returns 0 with NO records (plan §2.5). `dig` is bundled
    # on macOS and queries dnsmasq's loopback :53 directly, bypassing the system
    # resolver. valet with tld=localhost registers /etc/resolver/localhost + a
    # dnsmasq zone, so a healthy stack returns the loopback address.
    local ans
    ans="$(dig @127.0.0.1 probe.localhost +time=1 +tries=1 +short 2>/dev/null)"
    if [[ "$ans" != "127.0.0.1" && "$ans" != "::1" ]]; then
        VALET_STACK_FAILURE="dnsmasq"
        return 1
    fi
    return 0
}

_valet_wait_for_stack() {
    local attempts="${VALET_STACK_VERIFY_ATTEMPTS:-5}" n
    [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || attempts=5
    for ((n=1; n<=attempts; n++)); do
        _valet_stack_ok && return 0
        (( n < attempts )) && sleep 1
    done
    return 1
}

_valet_report_stack_failure() {
    local component="${VALET_STACK_FAILURE:-unknown}" php_log
    php_log="${MESH_HOMEBREW_LOG_DIR:-/var/log/homebrew}/php.log"
    echo "[valet] service post-condition failed after PHP health passed: $component is not serving. Run \`mesh doctor --fix\`; inspect $php_log and \`sudo launchctl print system/homebrew.mxcl.php\`" >&2
    if [[ "$component" == "php-fpm" && -r "$php_log" ]]; then
        local excerpt
        excerpt="$(tail -n 4 "$php_log" 2>/dev/null || true)"
        case "$excerpt" in
            *dyld*|*"Library not loaded"*|*"Operation not permitted"*|*sandbox*|*EX_CONFIG*)
                echo "[valet] LaunchDaemon/dyld/sandbox diagnostic from $php_log:" >&2
                printf '%s\n' "$excerpt" >&2
                ;;
        esac
    fi
}

check() {
    VALET_STACK_FAILURE=""
    _resolve_valet_bin
    [[ -x "$VALET_BIN" ]] || { VALET_STACK_FAILURE="valet-binary"; return 1; }
    [[ -d "$HOME/.config/valet" ]] || { VALET_STACK_FAILURE="valet-config"; return 1; }
    # TLD must be localhost. Read from config.json instead of `valet tld`,
    # because the CLI invokes sudo internally — the menu scanner stubs
    # sudo, so any `valet <cmd>` produces no output and fakes "not installed".
    local cfg="$HOME/.config/valet/config.json"
    [[ -f "$cfg" ]] || { VALET_STACK_FAILURE="valet-config"; return 1; }
    grep -q '"tld"[[:space:]]*:[[:space:]]*"localhost"' "$cfg" \
        || { VALET_STACK_FAILURE="valet-tld"; return 1; }
    # External parked volume unmounted → nothing to serve; DEFER (treat as OK so
    # the engine does not trigger a repair that would mkdir a phantom path).
    if _valet_external_unmounted; then
        echo "[valet] CODE_DIR ($CODE_DIR) on an unmounted external volume — deferring stack probe" >&2
        return 0
    fi
    # Operational: the serving stack must actually be up. Previously check() was
    # config-marker only, so it returned 0 (engine KEEP) while every daemon was
    # down — the audit's live critical. This makes check() operational, sudo-free.
    _valet_stack_ok
}

install() {
    # External parked volume unmounted → DEFER: do not `mkdir -p` a phantom path
    # nor run valet install against a volume that isn't there (plan D-3). Repairs
    # and normal runs both skip cleanly until the volume is back.
    if _valet_external_unmounted; then
        echo "[valet] CODE_DIR ($CODE_DIR) on an unmounted external volume — skipping install/park (deferred)" >&2
        return 0
    fi

    _valet_php_probe_clean || return 1
    _resolve_valet_bin
    if [[ ! -x "$VALET_BIN" ]]; then
        composer global require laravel/valet --no-interaction --quiet
        _resolve_valet_bin   # bin-dir now populated — re-resolve
    fi
    [[ -x "$VALET_BIN" ]] || { echo "[valet] composer install failed" >&2; return 1; }

    mkdir -p "$CODE_DIR"

    # `valet install` is load-bearing: it creates ~/.config/valet, which
    # post-verify check() asserts. A swallowed failure here re-surfaces as a
    # confusing rc67 whole-run abort, so capture its rc and fail cleanly.
    local need_install=0
    if [[ "${FORCE_VALET_INSTALL:-0}" == "1" ]]; then
        need_install=1
    elif [[ ! -d "$HOME/.config/valet" ]] || ! "$VALET_BIN" --version >/dev/null 2>&1; then
        need_install=1
    elif ! _valet_stack_ok; then
        # Config present and the CLI works, but the serving stack is DOWN. The
        # old conditions stopped here (valet --version succeeds → skip), so a
        # rebooted machine with stopped daemons silently kept a dead valet. Now
        # we re-run `valet install` to re-register & start nginx/dnsmasq/php-fpm.
        echo "[valet] serving stack down (nginx/dnsmasq/php-fpm) — re-running valet install" >&2
        need_install=1
    else
        echo "[valet] skipping valet install (already configured & serving — set FORCE_VALET_INSTALL=1 to re-run)"
    fi
    if [[ "$need_install" == "1" ]]; then
        _valet_harden_launchdaemons || return $?
        local valet_install_out="" valet_install_rc=0
        valet_install_out="$("$VALET_BIN" install 2>&1)" || valet_install_rc=$?
        if [[ "$valet_install_rc" -ne 0 ]]; then
            _valet_report_install_failure "$valet_install_out" "$valet_install_rc"
            return "$valet_install_rc"
        fi
        [[ -n "$valet_install_out" ]] && printf '%s\n' "$valet_install_out"
        # Valet can regenerate the plists it just installed. Re-harden after the
        # command and propagate bootstrap failures before checking liveness.
        _valet_harden_launchdaemons || return $?
    fi

    # Refresh sudo cache (`valet tld` and `valet park` will sudo).
    sudo -v 2>/dev/null || true

    # Align TLD with WSL — .localhost is RFC 6761 browser-native. check()
    # asserts the configured tld is localhost, so a real failure here must
    # surface as install-failed, not a downstream verify abort.
    local current_tld
    current_tld="$("$VALET_BIN" tld 2>/dev/null | tr -d '\r' || true)"
    if [[ "$current_tld" != "localhost" ]]; then
        if ! printf 'y\n' | "$VALET_BIN" tld localhost; then
            echo "[valet] tld localhost failed — sites may still resolve on .test" >&2
            return 1
        fi
    fi

    # Parking is best-effort — check() does not assert it.
    ( cd "$CODE_DIR" && "$VALET_BIN" park ) || true

    if ! _valet_wait_for_stack; then
        _valet_report_stack_failure
        return 1
    fi
}

verify() {
    _valet_php_probe_clean || return 1
    if ! check; then
        _valet_report_stack_failure
        return 1
    fi
    return 0
}

repair() {
    # Engine --repair sweep: force the serving stack back up THROUGH the
    # installer (governing principle §0 — no manual `valet restart`). FORCE makes
    # install() re-run `valet install` even when config markers look fine;
    # install() still defers on an unmounted external volume.
    FORCE_VALET_INSTALL=1 install
}

_valet_bootout_service() {
    local svc="$1" launchctl_bin="${MESH_LAUNCHCTL_BIN:-launchctl}"
    if [[ -n "${MESH_LAUNCHCTL_BIN:-}" ]]; then
        sudo "$launchctl_bin" bootout "system/homebrew.mxcl.${svc}" >/dev/null 2>&1 || true
    else
        sudo launchctl bootout "system/homebrew.mxcl.${svc}" >/dev/null 2>&1 || true
    fi
}

_valet_remove_known_path() {
    local path="$1"
    local target
    case "$path" in
        "$HOME/.composer/vendor/bin/valet"|\
        "$HOME/.composer/vendor/laravel/valet"|\
        "$HOME/.config/composer/vendor/bin/valet"|\
        "$HOME/.config/composer/vendor/laravel/valet"|\
        "$HOME/.config/valet")
            ;;
        *)
            echo "[valet] refusing unsafe uninstall path: $path" >&2
            return 1
            ;;
    esac
    [[ -e "$path" || -L "$path" ]] || return 0
    target="$path"
    # `target` is L05-allowlisted after the exact Valet path guard above.
    rm -rf "$target"
}

_valet_remove_composer_package() {
    local rc=0
    if command -v composer >/dev/null 2>&1 && command -v php >/dev/null 2>&1; then
        composer global remove laravel/valet --no-interaction >/dev/null 2>&1 || true
    fi
    _valet_remove_known_path "$HOME/.composer/vendor/bin/valet" || rc=$?
    _valet_remove_known_path "$HOME/.composer/vendor/laravel/valet" || rc=$?
    _valet_remove_known_path "$HOME/.config/composer/vendor/bin/valet" || rc=$?
    _valet_remove_known_path "$HOME/.config/composer/vendor/laravel/valet" || rc=$?
    return "$rc"
}

uninstall() {
    local rc=0
    _valet_bootout_service php
    _valet_bootout_service nginx
    _valet_bootout_service dnsmasq
    _valet_remove_composer_package || rc=$?
    if [[ "${MESH_PURGE_DATA:-0}" == "1" ]]; then
        _valet_remove_known_path "$HOME/.config/valet" || rc=$?
    fi
    return "$rc"
}

rollback() {
    # Don't auto-uninstall Valet — extensive system state.
    :
}
