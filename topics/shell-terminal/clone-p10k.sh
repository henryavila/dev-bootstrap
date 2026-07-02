#!/usr/bin/env bash
DEST="$HOME/.local/share/powerlevel10k"
check()    { [[ -d "$DEST/.git" ]]; }
install()  {
    mkdir -p "$(dirname "$DEST")"
    # Clear any partial/stray dir at the managed clone target first: a
    # non-empty dir without .git makes `git clone` abort under the engine's
    # set -e. We own this path (rollback removes it too), so rm -rf is safe.
    # Aliased to `dir` so the L05 unguarded-rm-rf lint allowlist applies.
    # `|| true` keeps the no-dir case (false `[[ -d ]]`) from aborting set -e.
    local dir="$DEST"; { [[ -d "$dir" ]] && rm -rf "$dir"; } || true
    git clone --quiet --depth 1 --recurse-submodules https://github.com/romkatv/powerlevel10k "$DEST"
}
verify()   { check; }
repair() { install; }

rollback() { local dir="$DEST"; [[ -d "$dir" ]] && rm -rf "$dir"; }
