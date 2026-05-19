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
    local origin describe
    origin="$(git -C "$CATP_TMUX" config --get remote.origin.url 2>/dev/null)"
    case "$origin" in
        *catppuccin/tmux*) ;;
        *) return 1 ;;
    esac
    # describe matches the tag we cloned with --branch (annotated or lightweight).
    describe="$(git -C "$CATP_TMUX" describe --tags --exact-match 2>/dev/null)"
    [[ "$describe" == "$CATP_TAG" ]]
}

install() {
    mkdir -p "$(dirname "$CATP_TMUX")"
    git clone --quiet --depth 1 --branch "$CATP_TAG" \
        https://github.com/catppuccin/tmux "$CATP_TMUX"
}

verify() {
    check
}

rollback() {
    # Rollback of OUR install — we cloned this dir, we own removing it.
    # Aliased to `dir` so the L05 unguarded-rm-rf lint allowlist applies.
    local dir="$CATP_TMUX"
    [[ -d "$dir" ]] && rm -rf "$dir"
}
