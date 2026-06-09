# shellcheck shell=bash
# Driver: go-install. Installs Go package.
go_install_check()   { command -v "$(basename "$1")" >/dev/null 2>&1; }
go_install_install() { go install "$1"; }
