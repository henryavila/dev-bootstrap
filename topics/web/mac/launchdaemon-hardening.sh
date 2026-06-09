#!/usr/bin/env bash
# Custom: harden LaunchDaemons (Standard*Path) against phantom-volume mkdir
# at boot when BREW_PREFIX is on a noowners volume (/Volumes/External/...).
#
# Original incident: 2026-05-02. Root cause: launchd loads daemon before
# external disk mounts; O_CREAT on Standard*Path mkdir's parent on rootfs,
# colliding with the real mount point and causing disambiguation suffix.

_is_custom_prefix() {
    case "${BREW_PREFIX:-}" in
        /opt/homebrew|/usr/local|"") return 1 ;;
        *) return 0 ;;
    esac
}

_target_log_for() { printf '%s\n' "/var/log/homebrew/$1.log"; }

check() {
    # Homebrew LaunchDaemon plists are root:wheel mode 0644 — world-
    # readable. `test -f` and `PlistBuddy Print` both work without sudo
    # for these files (verified live 2026-05-28). Keeping check() sudo-
    # free lets the menu scanner probe state with zero password friction.
    _is_custom_prefix || return 0
    local svc plist current target
    for svc in php nginx dnsmasq; do
        plist="/Library/LaunchDaemons/homebrew.mxcl.${svc}.plist"
        test -f "$plist" || continue
        target="$(_target_log_for "$svc")"
        current="$(/usr/libexec/PlistBuddy -c "Print :StandardErrorPath" "$plist" 2>/dev/null || echo "")"
        [[ "$current" == "$target" ]] || return 1
    done
    return 0
}

install() {
    _is_custom_prefix || { echo "[launchdaemon-hardening] standard brew prefix — no-op"; return 0; }
    # Prime the sudo cache (every step below needs root). Matches valet.sh /
    # mkcert.sh — keeps --non-interactive runs from blocking on a password.
    sudo -v 2>/dev/null || true
    sudo mkdir -p /var/log/homebrew
    local svc plist target current_err current_out changed=0 found=0
    for svc in php nginx dnsmasq; do
        plist="/Library/LaunchDaemons/homebrew.mxcl.${svc}.plist"
        sudo test -f "$plist" || continue
        # shellcheck disable=SC2034  # advisory flag reserved for future reporting
        found=1
        target="$(_target_log_for "$svc")"
        current_err="$(sudo /usr/libexec/PlistBuddy -c "Print :StandardErrorPath" "$plist" 2>/dev/null || echo "")"
        current_out="$(sudo /usr/libexec/PlistBuddy -c "Print :StandardOutPath"   "$plist" 2>/dev/null || echo "")"
        if [[ "$current_err" != "$target" ]]; then
            # The edit is the load-bearing step verify() asserts. If Set AND
            # Add both fail (TCC/SIP write deny, sudo not cached), the path is
            # never written — fail loudly here instead of returning 0 and
            # letting post-verify surface it as an opaque engine rc67.
            if ! sudo /usr/libexec/PlistBuddy -c "Set :StandardErrorPath $target" "$plist" 2>/dev/null \
                && ! sudo /usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $target" "$plist"; then
                echo "[launchdaemon-hardening] failed to set StandardErrorPath on $plist" >&2
                return 1
            fi
            changed=1
        fi
        if [[ -n "$current_out" && "$current_out" != "$target" ]]; then
            sudo /usr/libexec/PlistBuddy -c "Set :StandardOutPath $target" "$plist"
            changed=1
        fi
    done
    if (( changed == 1 )); then
        for svc in php nginx dnsmasq; do
            plist="/Library/LaunchDaemons/homebrew.mxcl.${svc}.plist"
            sudo test -f "$plist" || continue
            sudo launchctl bootout "system/homebrew.mxcl.${svc}" >/dev/null 2>&1 || true
            sudo launchctl bootstrap system "$plist" >/dev/null 2>&1 \
                || echo "[launchdaemon-hardening] bootstrap of $svc failed (TCC sandbox + external noowners volume; pre-existing)" >&2
        done
    fi
    return 0
}

verify() {
    check
}

rollback() {
    # Hardening is purely defensive — leave it in place.
    :
}
