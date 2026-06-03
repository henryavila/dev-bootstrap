#!/usr/bin/env bash
# Custom installer: moshi-hook binary on Linux/WSL.
# Mac uses brew-formula item (rjyo/moshi/moshi-hook).
# Update = re-run this installer (curl script replaces the binary in-place).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/log.sh"

check() {
    command -v moshi-hook >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/moshi-hook" ]]
}

install() {
    info "installing moshi-hook via getmoshi.app installer"
    curl -fsSL https://getmoshi.app/install.sh | INSTALL_DIR="$HOME/.local/bin" sh
}

verify() {
    command -v moshi-hook >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/moshi-hook" ]]
}

rollback() {
    rm -f "$HOME/.local/bin/moshi-hook" "$HOME/.local/bin/moshi"
}
