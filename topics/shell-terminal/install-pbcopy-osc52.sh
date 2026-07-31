#!/usr/bin/env bash
# Custom installer: mesh pbcopy shim that dual-writes OSC 52 under Herdr.
#
# macOS only (platforms: [mac] in the manifest). On a local Mac, Grok writes
# only via native pbcopy; herdr --remote clients never see that clipboard.
# Installing ~/.local/bin/pbcopy (ahead of /usr/bin on PATH) fixes agent and
# shell copies while leaving the real system binary as the write backend.
#
# Contract: check / install / verify / repair / rollback / uninstall.

# Interactive zsh often aliases names like `rollback`; the engine sources this
# under bash, but operators may `.` the file in a login shell. Clear aliases
# so lifecycle functions always bind as functions.
unalias install check verify repair rollback uninstall update 2>/dev/null || true

readonly _MESH_PBCOPY_DST="${MESH_PBCOPY_INSTALL_DIR:-$HOME/.local/bin}/pbcopy"
readonly _MESH_PBCOPY_MARKER='mesh-pbcopy-osc52'

_mesh_pbcopy_src() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    printf '%s/bin/pbcopy' "$here"
}

_mesh_pbcopy_is_ours() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    grep -q "$_MESH_PBCOPY_MARKER" "$f" 2>/dev/null
}

check() {
    # Keep only when our shim is installed at the known path with the marker
    # and is executable. A foreign ~/.local/bin/pbcopy fails check so install
    # can refuse or replace via the content guard.
    [[ -x "$_MESH_PBCOPY_DST" ]] || return 1
    _mesh_pbcopy_is_ours "$_MESH_PBCOPY_DST" || return 1
    # Drift: re-install if the source evolved past the installed copy.
    local src
    src="$(_mesh_pbcopy_src)"
    [[ -f "$src" ]] || return 1
    cmp -s "$src" "$_MESH_PBCOPY_DST"
}

install() {
    local src dst_dir
    src="$(_mesh_pbcopy_src)"
    if [[ ! -f "$src" ]]; then
        printf 'install-pbcopy-osc52: source missing: %s\n' "$src" >&2
        return 1
    fi
    dst_dir="$(dirname "$_MESH_PBCOPY_DST")"
    mkdir -p "$dst_dir"

    # Refuse to clobber a foreign pbcopy that does not carry our marker.
    if [[ -e "$_MESH_PBCOPY_DST" ]] && ! _mesh_pbcopy_is_ours "$_MESH_PBCOPY_DST"; then
        printf 'install-pbcopy-osc52: refusing to overwrite foreign %s (no %s marker)\n' \
            "$_MESH_PBCOPY_DST" "$_MESH_PBCOPY_MARKER" >&2
        return 1
    fi

    # Atomic install: write temp in same dir then mv.
    local tmp
    tmp="$(mktemp "$dst_dir/.pbcopy.mesh.XXXXXX")" || return 1
    if ! cp "$src" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 0755 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$_MESH_PBCOPY_DST"
}

verify() {
    check
}

repair() {
    install
}

rollback() {
    if _mesh_pbcopy_is_ours "$_MESH_PBCOPY_DST"; then
        rm -f "$_MESH_PBCOPY_DST"
    fi
    return 0
}

uninstall() {
    rollback
    # Honest marker drop: our path is gone (or never was ours).
    if [[ -e "$_MESH_PBCOPY_DST" ]] && _mesh_pbcopy_is_ours "$_MESH_PBCOPY_DST"; then
        return 1
    fi
    return 0
}
