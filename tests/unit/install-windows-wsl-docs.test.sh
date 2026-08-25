#!/usr/bin/env bash
# Install docs for Windows → WSL stay aligned with the closed-loop product path.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

GUIDE="$WS/docs/INSTALL-WINDOWS-WSL.md"
README="$WS/README.md"
README_PT="$WS/README.pt-BR.md"
PS1="$WS/windows/install-wsl.ps1"

assert_file_exists "$GUIDE" "docs/INSTALL-WINDOWS-WSL.md exists"
assert_file_contains "$GUIDE" 'install-wsl.ps1' "guide documents host script"
assert_file_contains "$GUIDE" 'Ubuntu-24.04' "guide pins Ubuntu-24.04"
assert_file_contains "$GUIDE" 'lean bootstrap' "guide documents lean bootstrap"
assert_file_contains "$GUIDE" 'CaskaydiaCove' "guide documents CaskaydiaCove font ownership"
assert_file_contains "$GUIDE" 'git curl ca-certificates' "guide documents Phase 0 apt"
assert_file_contains "$GUIDE" 'wsl --shutdown' "guide documents systemd activation"
assert_file_contains "$GUIDE" 'MESH_IDENTITY_REPO' "guide documents identity env"

assert_file_contains "$README" 'docs/INSTALL-WINDOWS-WSL.md' "README links the install guide"
assert_file_contains "$README_PT" 'docs/INSTALL-WINDOWS-WSL.md' "README.pt-BR links the install guide"
assert_file_contains "$README" 'lean bootstrap' "README mentions lean bootstrap"
assert_file_contains "$README_PT" 'lean bootstrap' "README.pt-BR mentions lean bootstrap"

# Entrypoint next-steps must not resurrect the renamed repo / entrypoint.
if grep -nE 'dev-bootstrap|bootstrap\.sh' "$PS1" >/dev/null 2>&1; then
    fail "windows/install-wsl.ps1 must not mention dev-bootstrap or bootstrap.sh"
    grep -nE 'dev-bootstrap|bootstrap\.sh' "$PS1" | sed 's/^/      /' >&2
else
    pass "windows/install-wsl.ps1 has no stale bootstrap entrypoints"
fi
assert_file_contains "$PS1" 'INSTALL-WINDOWS-WSL.md' "PS1 next-steps point at the install guide"

MKCERT_FROM="$WS/topics/web/scripts/import-mkcert-from-windows.ps1"
MKCERT_SH="$WS/topics/web/wsl/mkcert.sh"
assert_file_exists "$MKCERT_FROM" "import-mkcert-from-windows.ps1 exists"
assert_file_exists "$MKCERT_SH" "topics/web/wsl/mkcert.sh exists"
if grep -nE 'dev-bootstrap|60-web-stack' "$MKCERT_FROM" >/dev/null 2>&1; then
    fail "import-mkcert-from-windows.ps1 must not mention dev-bootstrap or 60-web-stack"
    grep -nE 'dev-bootstrap|60-web-stack' "$MKCERT_FROM" | sed 's/^/      /' >&2
else
    pass "import-mkcert-from-windows.ps1 has no stale bootstrap paths"
fi
assert_file_contains "$MKCERT_SH" '%TEMP%' "mkcert stages CA on Windows TEMP (avoid \\\\wsl\$ deadlock)"

# PS 5.1: `("Ubuntu-24.04")[0].Trim()` throws — [char] has no Trim.
# A one-distro `wsl -l --quiet` hits that. Get-FirstToken must wrap -split in @().
if grep -nE '\)\[0\]\.Trim\(\)' "$MKCERT_FROM" >/dev/null 2>&1; then
    fail "import-mkcert-from-windows.ps1 must not index a split result with [0].Trim() (PS 5.1 [char] trap)"
    grep -nE '\)\[0\]\.Trim\(\)' "$MKCERT_FROM" | sed 's/^/      /' >&2
else
    pass "import-mkcert-from-windows.ps1 avoids PS 5.1 [char].Trim() trap"
fi
assert_file_contains "$MKCERT_FROM" 'function Get-FirstToken' \
    "import-mkcert-from-windows.ps1 defines Get-FirstToken for one-distro hosts"

summary
