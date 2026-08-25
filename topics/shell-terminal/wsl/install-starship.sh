#!/usr/bin/env bash
# Install into ~/.local/bin (already on PATH from mesh zshrc/bashrc). The
# upstream installer defaults to /usr/local/bin and blocks on a sudo password
# even with --yes — on a WSL pts that hangs until the engine soft_fail watchdog.
STARSHIP_BIN_DIR="${STARSHIP_BIN_DIR:-$HOME/.local/bin}"
check()   { command -v starship >/dev/null 2>&1; }
install() {
    set -o pipefail
    mkdir -p "$STARSHIP_BIN_DIR"
    curl -fsSL --connect-timeout 8 --max-time 45 https://starship.rs/install.sh \
        | sh -s -- --yes --bin-dir "$STARSHIP_BIN_DIR"
}
verify()  { check; }
repair() { install; }

rollback() {
    local p
    p=$(command -v starship 2>/dev/null) || p="$STARSHIP_BIN_DIR/starship"
    # Only remove a binary we placed under the user prefix.
    if [[ -x "$p" && "$p" == "$STARSHIP_BIN_DIR/starship" ]]; then
        rm -f "$p"
    fi
}
