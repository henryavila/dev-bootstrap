#!/usr/bin/env bash
# diagnose-wsl-interop.sh always prints a Lane-B Windows CA import command
# with an absolute UNC (so `bash topics/web/scripts/...` still works).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

DIAG="$WS/topics/web/scripts/diagnose-wsl-interop.sh"
UNC_LIB="$WS/topics/web/scripts/mkcert-windows-unc.sh"
MKCERT_SH="$WS/topics/web/wsl/mkcert.sh"
assert_file_exists "$DIAG" "diagnose-wsl-interop.sh exists"
assert_file_exists "$UNC_LIB" "mkcert-windows-unc.sh exists"

assert_pattern_present "$DIAG" 'mkcert-windows-unc\.sh' \
    "diagnose sources the shared UNC helper"
assert_pattern_present "$DIAG" 'mesh_mkcert_from_windows_ps_cmd' \
    "diagnose prints the Lane-B PowerShell command from the helper"
assert_pattern_absent "$DIAG" 'ONLY_TOPICS=60-web-stack' \
    "does not revive dead ONLY_TOPICS=60-web-stack"
assert_pattern_absent "$DIAG" 'dirname "\$0"' \
    "does not use dirname \$0 for the UNC"
assert_pattern_absent "$DIAG" 'lsb_release' \
    "does not use lsb_release -si as the WSL distro name"
assert_pattern_present "$UNC_LIB" 'import-mkcert-from-windows\.ps1' \
    "shared helper points at import-mkcert-from-windows.ps1"
assert_pattern_present "$DIAG" 'bash setup\.sh --bundle web/nginx-php-fpm' \
    "healthy-path reapply uses current --bundle API"
assert_pattern_present "$DIAG" 'clone root' \
    "healthy-path says to run setup from the clone root"

# The PowerShell command must print even when interop checks pass.
robust_line="$(grep -n 'ROBUST SOLUTION' "$DIAG" | head -1 | cut -d: -f1)"
fail_if_line="$(grep -n 'if \[\[ -n "\$FIRST_FAIL" \]\]' "$DIAG" | head -1 | cut -d: -f1)"
if [[ -n "$robust_line" && -n "$fail_if_line" ]] && (( robust_line < fail_if_line )); then
    pass "ROBUST SOLUTION is printed before the FIRST_FAIL gate"
else
    fail "ROBUST SOLUTION must print even when interop checks pass (before FIRST_FAIL if)"
fi

# shellcheck source=/dev/null
. "$UNC_LIB"
scripts_dir="/home/h/mesh-workstation/topics/web/scripts"
got="$(WSL_DISTRO_NAME=Ubuntu-24.04 mesh_mkcert_from_windows_unc "$scripts_dir")"
want='\\wsl.localhost\Ubuntu-24.04\home\h\mesh-workstation\topics\web\scripts\import-mkcert-from-windows.ps1'
assert_eq "$got" "$want" "UNC is absolute \\\\wsl.localhost\\<distro>\\... from \$HERE"

got_unset="$(env -u WSL_DISTRO_NAME bash -c '
    # shellcheck source=/dev/null
    . "$1"
    mesh_mkcert_from_windows_unc "$2"
' _ "$UNC_LIB" "$scripts_dir")"
assert_contains "$got_unset" '<WSL_DISTRO_NAME>' \
    "unset WSL_DISTRO_NAME does not invent Ubuntu from lsb_release"
assert_not_contains "$got_unset" '\\wsl.localhost\Ubuntu\' \
    "unset WSL_DISTRO_NAME does not use lsb_release -si Ubuntu"

assert_file_contains "$MKCERT_SH" 'mesh_mkcert_from_windows_ps_cmd' \
    "mkcert followup uses the shared Lane-B PowerShell command"
assert_pattern_absent "$MKCERT_SH" '~/mesh-workstation/topics/web/scripts/import-mkcert' \
    "mkcert followup is not a WSL ~/mesh-workstation -File path"

summary
