# shellcheck shell=bash
# Driver: github-release. Downloads latest release tarball into ~/.local/bin.
# spec format: owner/repo
github_release_check()   { command -v "$(basename "$1")" >/dev/null 2>&1; }
github_release_install() {
    local repo="$1" tmp
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    gh release download --repo "$repo" --dir "$tmp" --pattern '*.tar.gz' 2>/dev/null \
        || { echo "github-release: gh CLI required (install: gh auth login)"; return 1; }
    tar -xzf "$tmp"/*.tar.gz -C "$tmp"
    mv "$tmp"/*/bin/* ~/.local/bin/ 2>/dev/null || mv "$tmp"/* ~/.local/bin/
}
