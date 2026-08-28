#!/usr/bin/env bash
# Copy the workstation tree onto the Linux ext4 filesystem and strip CRLF
# so Windows-checkout scripts do not explode under bash.
set -euo pipefail
src="${MESH_SRC:?MESH_SRC is required}"
dst="${MESH_DST:-$HOME/mesh-workstation}"
rm -rf "$dst"
mkdir -p "$dst"
tar -C "$src" \
    --exclude=.git \
    --exclude=scripts/menu/node_modules \
    --exclude=.catalog \
    -cf - . | tar -C "$dst" -xf -
find "$dst" -type f \( -name '*.sh' -o -name '*.template' -o -name 'mesh' \) -print0 \
    | xargs -0 sed -i 's/\r$//'
test -f "$dst/scripts/runners/reinstall.sh"
test -f "$dst/scripts/lib/reinstall-shell.sh"
echo "COPY_OK $dst"
