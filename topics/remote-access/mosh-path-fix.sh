#!/usr/bin/env bash
# Custom installer: PATH fix for non-standard brew prefix.
# sshd-exec (where `mosh-server` is launched) doesn't source ~/.zshrc;
# its PATH comes from path_helper, which reads /etc/paths.d/*. We
# register the external-brew bin/sbin paths there and also symlink
# mosh-server into /usr/local/bin (always on default PATH) as a
# belt-and-suspenders for older mosh clients.

_paths_file() {
    printf '%s\n' "/etc/paths.d/60-extbrew"
}

check() {
    # Standard brew prefix → nothing to do.
    case "${BREW_PREFIX:-}" in
        /opt/homebrew|/usr/local|"") return 0 ;;
    esac
    # Non-standard: both paths must be in /etc/paths.d/60-extbrew AND
    # mosh-server must be reachable via /usr/local/bin.
    #
    # /etc/paths.d/* files are root:wheel mode 0644 — world-readable, so
    # the grep doesn't need sudo. Keeping check() sudo-free lets the menu
    # scanner probe state with zero password friction.
    local f
    f="$(_paths_file)"
    [[ -f "$f" ]] || return 1
    grep -q -F "$BREW_PREFIX/bin"  "$f" || return 1
    grep -q -F "$BREW_PREFIX/sbin" "$f" || return 1
    # mosh-server reachable via /usr/local/bin AND its dylibs actually resolve.
    # A bare `-x` passed even when the symlink target was broken (e.g. mosh not
    # yet rebuilt after a protobuf major-bump → dyld abort) — the audit's
    # filesystem false-keep. The static Mach-O resolver reports that as broken;
    # it is fixed transitively when mosh-mac reinstalls first. Falls back to -x
    # when the resolver helper is unavailable (e.g. invoked outside the engine).
    local resolver="${MESH_LIB_DIR:-}/mach-o-resolvable.sh"
    if [[ -n "${MESH_LIB_DIR:-}" && -r "$resolver" ]]; then
        bash "$resolver" /usr/local/bin/mosh-server || return 1
    else
        [[ -x /usr/local/bin/mosh-server ]] || return 1
    fi
    return 0
}

install() {
    case "${BREW_PREFIX:-}" in
        /opt/homebrew|/usr/local|"")
            echo "[mosh-path-fix] standard brew prefix — skipping"
            return 0
            ;;
    esac
    local f
    f="$(_paths_file)"
    for p in "$BREW_PREFIX/bin" "$BREW_PREFIX/sbin"; do
        if ! sudo grep -q -F "$p" "$f" 2>/dev/null; then
            echo "$p" | sudo tee -a "$f" >/dev/null
        fi
    done
    sudo mkdir -p /usr/local/bin
    if [[ -x "$BREW_PREFIX/bin/mosh-server" ]]; then
        sudo ln -sf "$BREW_PREFIX/bin/mosh-server" /usr/local/bin/mosh-server
        echo "[mosh-path-fix] symlinked mosh-server → /usr/local/bin/mosh-server (belt-and-suspenders for sshd-exec PATH)"
    fi
}

verify() {
    check
}

repair() {
    # Engine --repair sweep: re-register the paths.d entries + re-symlink
    # mosh-server. A broken dylib target is fixed transitively by mosh-mac
    # reinstalling first in the same sweep; this re-links to the healthy binary.
    # Idempotent and safe to re-run.
    install
}

rollback() {
    # Removing the paths file would affect other tools that may have
    # come to depend on it. Leave in place.
    :
}
