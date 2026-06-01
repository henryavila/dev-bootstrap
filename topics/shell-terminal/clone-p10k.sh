#!/usr/bin/env bash
DEST="$HOME/.local/share/powerlevel10k"
check()    { [[ -d "$DEST/.git" ]]; }
install()  {
    mkdir -p "$(dirname "$DEST")"
    git clone --quiet --depth 1 --recurse-submodules https://github.com/romkatv/powerlevel10k "$DEST"
}
verify()   { check; }
rollback() { local dir="$DEST"; [[ -d "$dir" ]] && rm -rf "$dir"; }
