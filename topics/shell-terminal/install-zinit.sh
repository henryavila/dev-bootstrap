#!/usr/bin/env bash
ZINIT_DIR="$HOME/.local/share/zinit"
check()    { [[ -f "$ZINIT_DIR/zinit.git/zinit.zsh" ]]; }
install()  {
    mkdir -p "$ZINIT_DIR"
    # Pipe "n" so the installer leaves ~/.zshrc alone (workstation owns it)
    yes n | bash -c "$(curl --fail --show-error --silent --location \
        https://raw.githubusercontent.com/zdharma-continuum/zinit/HEAD/scripts/install.sh)" \
        >/dev/null 2>&1 || true
    check || { echo "[zinit] install state check failed — shell will degrade gracefully" >&2; return 1; }
}
verify()   { check; }
rollback() { local dir="$ZINIT_DIR"; [[ -d "$dir" ]] && rm -rf "$dir"; }
