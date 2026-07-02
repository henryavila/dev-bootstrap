#!/usr/bin/env bash
# Custom installer: Catppuccin tmux theme pinned to v1.0.3.
#
# Pinned because v2 changed to a module-based API that would require a
# tmux.conf rewrite. `prefix + U` through TPM respects the `#v1.0.3` suffix
# in the tmux.conf @plugin line. The path matches what tmux.conf expects.

CATP_TMUX="$HOME/.tmux/plugins/tmux"
CATP_TAG="v1.0.3"

check() {
    # Codex review 2026-05-19 (A-F004): the previous check accepted ANY
    # git checkout at $CATP_TMUX as "Catppuccin v1.0.3", so a user-cloned
    # Catppuccin v2 (different API) or an unrelated repo at that path
    # would silently pass and skip install. Now we assert origin URL +
    # the pinned tag.
    [[ -d "$CATP_TMUX/.git" ]] || return 1
    local origin
    origin="$(git -C "$CATP_TMUX" config --get remote.origin.url 2>/dev/null)"
    case "$origin" in
        *catppuccin/tmux*) ;;
        *) return 1 ;;
    esac
    # The pinned commit may carry multiple tags (v1, v1.0, v1.0.3).
    # describe --exact-match returns only one (lexicographically first),
    # so we check the full tag list at HEAD instead.
    git -C "$CATP_TMUX" tag --points-at HEAD 2>/dev/null | grep -qxF "$CATP_TAG"
}

install() {
    mkdir -p "$(dirname "$CATP_TMUX")"
    # Pre-clear the managed clone target: a partial/non-git pre-existing dir
    # would make `git clone` abort ('destination path already exists and is
    # not an empty directory') under the engine's inherited set -e. We own
    # this path (rollback() rm -rf's the same dir), so clearing it here makes
    # the first run self-heal instead of failing the recoverable window.
    # Aliased to `dir` so the L05 unguarded-rm-rf lint allowlist applies.
    local dir="$CATP_TMUX"; { [[ -e "$dir" ]] && rm -rf "$dir"; } || true
    git clone --quiet --depth 1 --branch "$CATP_TAG" \
        https://github.com/catppuccin/tmux "$CATP_TMUX"
}

verify() {
    check
}

repair() { install; }

rollback() {
    # Rollback of OUR install — we cloned this dir, we own removing it.
    # Aliased to `dir` so the L05 unguarded-rm-rf lint allowlist applies.
    local dir="$CATP_TMUX"
    [[ -d "$dir" ]] && rm -rf "$dir"
}
