#!/usr/bin/env bash
# shellcheck shell=bash
# state-dir.sh — canonical mesh state directory + one-shot legacy migration.
# Source-only (no execution side effects beyond defining functions).
#
# Canonical per-host/per-install state lives at $XDG_STATE_HOME/mesh
# (i.e. ~/.local/state/mesh): install markers (installed/), secrets.env,
# auto-update markers (last-applied-*, locks), migrate-rollback snapshots/lock.
# Config (config.env, params.env, selections.list) lives separately under
# ~/.config/mesh and is NOT touched here.
#
# History (audit T-004): the state dir was renamed dev-bootstrap →
# mesh-workstation → mesh. The two prior names are migrated one-shot by
# mesh_migrate_legacy_state(): contents are moved into the canonical dir and the
# legacy dir is removed (decision D2 = move-and-remove). Idempotent + safe: a
# file already present in the canonical dir wins (its stale legacy copy is
# dropped), so re-running never clobbers current state.

# Canonical state dir. Override with MESH_STATE_DIR (tests / non-standard hosts).
mesh_state_dir() {
    printf '%s' "${MESH_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/mesh}"
}

# Move legacy state dirs into the canonical one, then remove them.
mesh_migrate_legacy_state() {
    local canon; canon="$(mesh_state_dir)"
    mkdir -p "$canon" 2>/dev/null || return 0
    local legacy target base moved=0
    for legacy in "$HOME/.local/state/dev-bootstrap" "$HOME/.local/state/mesh-workstation"; do
        [ -d "$legacy" ] || continue
        [ "$legacy" = "$canon" ] && continue
        # Iterate visible + dotfile entries; literal globs (no match) are skipped
        # by the -e guard, so no nullglob toggle is needed (bash 3.2 safe).
        # `target` is an L05-allowlisted scope name: it is always a path strictly
        # under $legacy (a mesh state dir), never empty or '/'.
        for target in "$legacy"/* "$legacy"/.[!.]*; do
            [ -e "$target" ] || continue
            base="${target##*/}"
            if [ -e "$canon/$base" ]; then
                rm -rf "$target" 2>/dev/null   # canonical wins; drop stale legacy copy
            elif mv "$target" "$canon/$base" 2>/dev/null; then
                moved=1
            fi
        done
        rmdir "$legacy" 2>/dev/null            # succeeds only once fully drained
    done
    [ "$moved" = 1 ] && printf 'mesh: migrated legacy state → %s\n' "$canon" >&2
    return 0
}
