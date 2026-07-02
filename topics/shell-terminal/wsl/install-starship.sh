#!/usr/bin/env bash
check()   { command -v starship >/dev/null 2>&1; }
install() { set -o pipefail; curl -fsSL https://starship.rs/install.sh | sh -s -- --yes; }
verify()  { check; }
repair() { install; }

rollback() {
    # Resolve the real install path (BIN_DIR may differ from /usr/local/bin);
    # fall back to the installer's Linux default.
    local p; p=$(command -v starship 2>/dev/null) || p=/usr/local/bin/starship
    [[ -x "$p" ]] && sudo rm -f "$p"
}
