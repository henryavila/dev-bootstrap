#!/usr/bin/env bash
check() { command -v lazygit >/dev/null 2>&1; }

install() {
    local ver tmp
    ver="$(curl -fsSL "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | jq -r '.tag_name' | sed 's/^v//')"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/lg.tgz" \
        "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${ver}_Linux_x86_64.tar.gz"
    tar -C "$tmp" -xzf "$tmp/lg.tgz" lazygit
    sudo install -m 0755 "$tmp/lazygit" /usr/local/bin/lazygit
    rm -rf "$tmp"
}

verify()  { check; }
rollback() { [[ -x /usr/local/bin/lazygit ]] && sudo rm -f /usr/local/bin/lazygit; }
