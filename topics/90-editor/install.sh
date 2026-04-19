#!/usr/bin/env bash
# 90-editor: installs the typora-wait wrapper so `EDITOR=typora-wait` works.
# No actual app install (Typora is a GUI installed separately).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

mkdir -p "$HOME/.local/bin"
ok "90-editor: typora-wait wrapper will be deployed from templates/"
