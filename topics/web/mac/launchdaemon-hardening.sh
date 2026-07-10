#!/usr/bin/env bash
# Custom: harden LaunchDaemons (Standard*Path) against phantom-volume mkdir
# at boot when BREW_PREFIX is on a noowners volume (/Volumes/External/...).
#
# Original incident: 2026-05-02. Root cause: launchd loads daemon before
# external disk mounts; O_CREAT on Standard*Path mkdir's parent on rootfs,
# colliding with the real mount point and causing disambiguation suffix.

_launchdaemon_is_custom_prefix() {
    case "${BREW_PREFIX:-}" in
        /opt/homebrew|/usr/local|"") return 1 ;;
        *) return 0 ;;
    esac
}

_launchdaemon_target_log_for() {
    printf '%s\n' "${MESH_HOMEBREW_LOG_DIR:-/var/log/homebrew}/$1.log"
}

_launchdaemon_report_activation_failure() {
    local svc="$1" rc="$2" output="$3" target
    target="$(_launchdaemon_target_log_for "$svc")"
    [[ -n "$output" ]] && printf '%s\n' "$output" >&2
    case "$output" in
        *dyld*|*"Library not loaded"*|*"Operation not permitted"*|*sandbox*|*EX_CONFIG*|*" 78"*)
            echo "[launchdaemon-hardening] LaunchDaemon/dyld/sandbox activation failed for $svc (rc=$rc); inspect $target and run \`mesh doctor --fix\` after PHP is clean" >&2
            ;;
        *)
            echo "[launchdaemon-hardening] LaunchDaemon activation failed for $svc (rc=$rc); inspect $target and run \`mesh doctor --fix\`" >&2
            ;;
    esac
}

_launchdaemon_bootout() {
    local svc="$1" launchctl_bin="$2"
    if [[ -n "${MESH_LAUNCHCTL_BIN:-}" ]]; then
        sudo "$launchctl_bin" bootout "system/homebrew.mxcl.${svc}"
    else
        sudo launchctl bootout "system/homebrew.mxcl.${svc}"
    fi
}

_launchdaemon_bootstrap() {
    local plist="$1" launchctl_bin="$2"
    if [[ -n "${MESH_LAUNCHCTL_BIN:-}" ]]; then
        sudo "$launchctl_bin" bootstrap system "$plist"
    else
        sudo launchctl bootstrap system "$plist"
    fi
}

_launchdaemon_print() {
    local svc="$1" launchctl_bin="$2"
    if [[ -n "${MESH_LAUNCHCTL_BIN:-}" ]]; then
        sudo "$launchctl_bin" print "system/homebrew.mxcl.${svc}"
    else
        sudo launchctl print "system/homebrew.mxcl.${svc}"
    fi
}

_launchdaemon_wait_running() {
    local svc="$1" launchctl_bin="$2"
    local attempts="${MESH_LAUNCHDAEMON_VERIFY_ATTEMPTS:-5}" n state_out="" state_rc=0
    [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || attempts=5
    for ((n=1; n<=attempts; n++)); do
        state_rc=0
        state_out="$(_launchdaemon_print "$svc" "$launchctl_bin" 2>&1)" || state_rc=$?
        if [[ "$state_rc" -eq 0 && "$state_out" == *"state = running"* ]]; then
            return 0
        fi
        (( n < attempts )) && sleep 1
    done
    local report_rc="$state_rc"
    [[ "$report_rc" -eq 0 ]] && report_rc=1
    _launchdaemon_report_activation_failure "$svc" "$report_rc" \
        "${state_out:-launchctl print returned no running state for system/homebrew.mxcl.${svc}}"
    return 1
}

launchdaemon_harden_check() {
    # Homebrew LaunchDaemon plists are root:wheel mode 0644 — world-
    # readable. `test -f` and `PlistBuddy Print` both work without sudo
    # for these files (verified live 2026-05-28). Keeping check() sudo-
    # free lets the menu scanner probe state with zero password friction.
    _launchdaemon_is_custom_prefix || return 0
    local svc plist current target
    local daemon_dir="${MESH_LAUNCHDAEMON_DIR:-/Library/LaunchDaemons}"
    local plistbuddy="${MESH_PLISTBUDDY_BIN:-/usr/libexec/PlistBuddy}"
    for svc in php nginx dnsmasq; do
        plist="$daemon_dir/homebrew.mxcl.${svc}.plist"
        test -f "$plist" || continue
        target="$(_launchdaemon_target_log_for "$svc")"
        current="$("$plistbuddy" -c "Print :StandardErrorPath" "$plist" 2>/dev/null || echo "")"
        [[ "$current" == "$target" ]] || return 1
    done
    return 0
}

launchdaemon_harden_install() {
    _launchdaemon_is_custom_prefix || { echo "[launchdaemon-hardening] standard brew prefix — no-op"; return 0; }
    local daemon_dir="${MESH_LAUNCHDAEMON_DIR:-/Library/LaunchDaemons}"
    local log_dir="${MESH_HOMEBREW_LOG_DIR:-/var/log/homebrew}"
    local plistbuddy="${MESH_PLISTBUDDY_BIN:-/usr/libexec/PlistBuddy}"
    local launchctl_bin="${MESH_LAUNCHCTL_BIN:-launchctl}"
    # Prime the sudo cache (every step below needs root). Matches valet.sh /
    # mkcert.sh — keeps --non-interactive runs from blocking on a password.
    sudo -v 2>/dev/null || true
    local mkdir_rc=0
    if [[ -n "${MESH_HOMEBREW_LOG_DIR:-}" ]]; then
        sudo mkdir -p "$log_dir" || mkdir_rc=$?
    else
        sudo mkdir -p /var/log/homebrew || mkdir_rc=$?
    fi
    if [[ "$mkdir_rc" -ne 0 ]]; then
        echo "[launchdaemon-hardening] failed to create $log_dir" >&2
        return 1
    fi
    local svc plist target current_err current_out changed=0 found=0
    for svc in php nginx dnsmasq; do
        plist="$daemon_dir/homebrew.mxcl.${svc}.plist"
        sudo test -f "$plist" || continue
        found=1
        target="$(_launchdaemon_target_log_for "$svc")"
        current_err="$(sudo "$plistbuddy" -c "Print :StandardErrorPath" "$plist" 2>/dev/null || echo "")"
        current_out="$(sudo "$plistbuddy" -c "Print :StandardOutPath"   "$plist" 2>/dev/null || echo "")"
        if [[ "$current_err" != "$target" ]]; then
            # The edit is the load-bearing step verify() asserts. If Set AND
            # Add both fail (TCC/SIP write deny, sudo not cached), the path is
            # never written — fail loudly here instead of returning 0 and
            # letting post-verify surface it as an opaque engine rc67.
            if ! sudo "$plistbuddy" -c "Set :StandardErrorPath $target" "$plist" 2>/dev/null \
                && ! sudo "$plistbuddy" -c "Add :StandardErrorPath string $target" "$plist"; then
                echo "[launchdaemon-hardening] failed to set StandardErrorPath on $plist" >&2
                return 1
            fi
            changed=1
        fi
        if [[ -n "$current_out" && "$current_out" != "$target" ]]; then
            if ! sudo "$plistbuddy" -c "Set :StandardOutPath $target" "$plist"; then
                echo "[launchdaemon-hardening] failed to set StandardOutPath on $plist" >&2
                return 1
            fi
            changed=1
        fi
    done
    if (( found == 0 )); then
        echo "[launchdaemon-hardening] no Valet LaunchDaemon plists found — run FORCE_VALET_INSTALL=1 to (re)create the web stack"
        return 0
    fi
    if (( changed == 1 )); then
        for svc in php nginx dnsmasq; do
            plist="$daemon_dir/homebrew.mxcl.${svc}.plist"
            sudo test -f "$plist" || continue
            _launchdaemon_bootout "$svc" "$launchctl_bin" >/dev/null 2>&1 || true
            local bootstrap_out="" bootstrap_rc=0
            bootstrap_out="$(_launchdaemon_bootstrap "$plist" "$launchctl_bin" 2>&1)" || bootstrap_rc=$?
            if [[ "$bootstrap_rc" -ne 0 ]]; then
                _launchdaemon_report_activation_failure "$svc" "$bootstrap_rc" "$bootstrap_out"
                return "$bootstrap_rc"
            fi
            if ! _launchdaemon_wait_running "$svc" "$launchctl_bin"; then
                return 1
            fi
        done
    fi
    return 0
}

launchdaemon_harden_verify() { launchdaemon_harden_check; }
launchdaemon_harden_repair() { launchdaemon_harden_install; }
launchdaemon_harden_rollback() { :; }

# The Valet lifecycle sources this file as a helper so hardening can happen
# before its final service post-condition. The manifest item still needs the
# generic custom-driver verbs when this script is sourced directly.
if [[ "${MESH_LAUNCHDAEMON_HARDENING_LIB_ONLY:-0}" != "1" ]]; then
    check() { launchdaemon_harden_check; }
    install() { launchdaemon_harden_install; }
    verify() { launchdaemon_harden_verify; }
    repair() { launchdaemon_harden_repair; }
    rollback() { launchdaemon_harden_rollback; }
fi
