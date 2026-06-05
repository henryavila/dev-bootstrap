# Driver: apt. Installs Debian/Ubuntu package.
# CP4 A2-F-003: dpkg-query asserts "install ok installed" status —
# previous `dpkg -s` accepted packages left in config-files state (post-
# removal residue) as installed, causing skip-then-missing-binary bugs.
# CP4 A2-F-002: `--` separator stops option parsing so a manifest spec
# starting with `-` is treated as a package name, not a flag.
apt_check()   { dpkg-query -W -f='${Status}\n' -- "$1" 2>/dev/null | grep -q '^install ok installed$'; }

# Refresh the package index at most once per ~hour. apt_install runs per item
# (each in its own engine subshell), so an in-memory guard wouldn't persist;
# instead we gate on the freshness of /var/lib/apt/lists — installing N apt
# items in one engine run re-fetches at most once. A stale/empty index is the
# usual cause of "Unable to locate package" on a freshly-imaged WSL box.
_apt_update_if_stale() {
    if [[ -z "$(find /var/lib/apt/lists -maxdepth 1 -type f -mmin -60 2>/dev/null)" ]]; then
        sudo -E apt-get update
    fi
}

# Noninteractive end to end: DEBIAN_FRONTEND stops debconf prompts (sudo -E
# carries it through), and Dpkg::Options::=--force-confold keeps the existing
# config file on conflict instead of blocking on the interactive "(Y/I/N/O)"
# dpkg prompt — both required for unattended WSL installs.
apt_install() {
    export DEBIAN_FRONTEND=noninteractive
    _apt_update_if_stale
    sudo -E apt-get install -y -o Dpkg::Options::=--force-confold -- "$1"
}

# Repair (engine --repair sweep): force-reinstall an installed-but-broken package.
# Plain `apt-get install` no-ops when the package is already the right version,
# so a repair needs --reinstall to actually re-lay the files.
apt_repair() {
    export DEBIAN_FRONTEND=noninteractive
    _apt_update_if_stale
    echo "apt: reinstalling $1 (repair)" >&2
    sudo -E apt-get install -y --reinstall -o Dpkg::Options::=--force-confold -- "$1"
}

# Version-aware update (T-600): refresh the index, then upgrade only if a newer
# candidate exists. `apt-get -s install --only-upgrade` simulates and prints an
# `Inst <pkg> ...` line exactly when it would actually upgrade.
apt_update() {
    export DEBIAN_FRONTEND=noninteractive
    _apt_update_if_stale
    if apt-get -s install --only-upgrade -- "$1" 2>/dev/null | grep -q "^Inst $1 "; then
        echo "apt: upgrading $1" >&2
        sudo -E apt-get install -y --only-upgrade -o Dpkg::Options::=--force-confold -- "$1"
    else
        echo "apt: $1 already latest" >&2
    fi
}
