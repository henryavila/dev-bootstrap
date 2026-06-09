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

uninstall() {
    # Reverse install(): the getmoshi.app installer drops moshi-hook (and a
    # `moshi` companion) into $HOME/.local/bin. Remove only those two
    # mesh-managed binaries — never the dir, never anything else under
    # ~/.local/bin. Same path set rollback() cleans, scoped to the installer's
    # INSTALL_DIR. On mac the brew-formula item owns moshi-hook, so this custom
    # script's uninstall() is the Linux/WSL path; the rm is a harmless no-op if
    # the binaries are already gone.
    rm -f "$HOME/.local/bin/moshi-hook" "$HOME/.local/bin/moshi" 2>/dev/null || true
    # Success = moshi-hook is actually gone (PATH or the known install path), so
    # the engine's marker drop is honest (the ngrok pattern). pipefail-safe:
    # no `tool | grep` here, just direct probes.
    ! command -v moshi-hook >/dev/null 2>&1 && [[ ! -e "$HOME/.local/bin/moshi-hook" ]]
}
