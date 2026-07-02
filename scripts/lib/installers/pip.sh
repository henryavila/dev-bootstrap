# shellcheck shell=bash
# Driver: pip. Installs Python package (user-level).
pip_check()   { pip show "$1" >/dev/null 2>&1; }
pip_verify() { pip_check "$1"; }
pip_install() { pip install --user "$1"; }
pip_repair() { pip install --user --force-reinstall "$1"; }
