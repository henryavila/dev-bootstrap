# shellcheck shell=bash
# Service descriptor: mysql — MySQL server (databases topic).
#   wsl → systemd unit `mysql` (matches topics/databases/wsl/mysql.sh).
#   mac → the mesh LaunchAgent when the Oracle run layer is installed;
#         otherwise the Homebrew formula (matches topics/databases/mac/mysql.sh).
# Opt-out at boot on WSL by default (T-006): kept installed but not autostarted
# unless the host's services.default opts it in.
svcdef_mysql_meta()   { echo "MySQL|mysqld|databases"; }
svcdef_mysql_wsl()    { echo "systemd|system|mysql"; }
svcdef_mysql_mac() {
    local user label
    user="${USER:-$(id -un)}"
    label="com.${user}.mysql"
    if [[ -n "${HOME:-}" && -f "${HOME}/Library/LaunchAgents/${label}.plist" ]]; then
        echo "launchd||${label}"
    else
        echo "brew||mysql"
    fi
}
svcdef_mysql_optout() { echo "wsl"; }
