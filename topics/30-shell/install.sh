#!/usr/bin/env bash
# 30-shell: modular bashrc/zshrc loader (OS-agnostic).
# Just ensures ~/.bashrc.d and ~/.zshrc.d directories exist; templates do the rest.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

mkdir -p "$HOME/.bashrc.d" "$HOME/.zshrc.d" "$HOME/.config" "$HOME/.local/bin"

ok "30-shell directories prepared"
