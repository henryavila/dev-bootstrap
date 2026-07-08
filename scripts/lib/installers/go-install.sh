# shellcheck shell=bash
# Driver: go-install. Installs Go package.
_go_install_binary_name() {
    local pkg="${1%%@*}"
    basename "$pkg"
}

go_install_check()   { command -v "$(_go_install_binary_name "$1")" >/dev/null 2>&1; }
go_install_verify() { go_install_check "$1"; }
go_install_install() { go install "$1"; }
go_install_repair() { go_install_install "$1"; }
