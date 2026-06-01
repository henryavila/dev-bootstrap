#!/usr/bin/env bash
check()   { command -v starship >/dev/null 2>&1; }
install() { curl -fsSL https://starship.rs/install.sh | sh -s -- --yes; }
verify()  { check; }
rollback() {
    [[ -x /usr/local/bin/starship ]] && sudo rm -f /usr/local/bin/starship
}
