# Driver: apt. Installs Debian/Ubuntu package.
apt_check()   { dpkg -s "$1" >/dev/null 2>&1; }
apt_install() { sudo apt-get install -y "$1"; }
