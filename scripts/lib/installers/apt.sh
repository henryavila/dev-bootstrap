# Driver: apt. Installs Debian/Ubuntu package.
# CP4 A2-F-003: dpkg-query asserts "install ok installed" status —
# previous `dpkg -s` accepted packages left in config-files state (post-
# removal residue) as installed, causing skip-then-missing-binary bugs.
# CP4 A2-F-002: `--` separator stops option parsing so a manifest spec
# starting with `-` is treated as a package name, not a flag.
apt_check()   { dpkg-query -W -f='${Status}\n' -- "$1" 2>/dev/null | grep -q '^install ok installed$'; }
apt_install() { sudo apt-get install -y -- "$1"; }
