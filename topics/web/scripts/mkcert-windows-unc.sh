# shellcheck shell=bash
# Source-only. Windows UNC for import-mkcert-from-windows.ps1 (Lane B).
#
# Lane A (WSL → powershell.exe) is import-mkcert-windows.ps1 + ROOTCA_PATH.
# Lane B (Windows → wsl.exe) is import-mkcert-from-windows.ps1 — this UNC.
#
# Do not use lsb_release -si for the distro: that prints "Ubuntu", while
# \\wsl.localhost\<Name>\ must be the WSL distro name (often Ubuntu-24.04).

mesh_mkcert_windows_distro() {
    if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
        printf '%s' "$WSL_DISTRO_NAME"
        return 0
    fi
    printf '%s' '<WSL_DISTRO_NAME>'
    return 1
}

# $1 = absolute WSL path of topics/web/scripts
mesh_mkcert_from_windows_unc() {
    local scripts_dir="$1"
    local distro
    distro="$(mesh_mkcert_windows_distro)" || true
    printf '%s' "\\\\wsl.localhost\\${distro}$(printf '%s' "$scripts_dir" | sed 's|/|\\|g')\\import-mkcert-from-windows.ps1"
}

mesh_mkcert_from_windows_ps_cmd() {
    printf "powershell -ExecutionPolicy Bypass -File '%s'" "$(mesh_mkcert_from_windows_unc "$1")"
}
