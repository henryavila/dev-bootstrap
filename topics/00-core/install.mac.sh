#!/usr/bin/env bash
# 00-core (mac): installs Homebrew if missing, then minimal tooling.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

# Install Homebrew if absent (trust the official installer)
if ! out=$(bash "$HERE/../../lib/detect-brew.sh" 2>/dev/null); then
    info "installing Homebrew"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Re-detect after install
    out=$(bash "$HERE/../../lib/detect-brew.sh")
fi
eval "$out"
ok "brew ready at $BREW_BIN"

pkgs=(
    git
    curl
    wget
    gnupg
    jq
    unzip
    gettext
)

for p in "${pkgs[@]}"; do
    if "$BREW_BIN" list --formula "$p" >/dev/null 2>&1; then
        ok "$p already installed"
    else
        info "brew install $p"
        "$BREW_BIN" install "$p"
    fi
done

# gettext is keg-only on macOS; envsubst must be reachable via PATH.
envsubst_path="$BREW_PREFIX/opt/gettext/bin/envsubst"
if [[ -x "$envsubst_path" ]] && ! command -v envsubst >/dev/null 2>&1; then
    warn "envsubst installed but not in PATH; add $BREW_PREFIX/opt/gettext/bin to PATH"
    warn "topic 30-shell handles this via bashrc.d/zshrc.d fragments"
fi

ok "00-core done"
