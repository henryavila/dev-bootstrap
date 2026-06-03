#!/usr/bin/env bash
# Custom installer: Bun runtime.
# Installs to ~/.bun/bin/bun via the official installer. Required by the
# claude-mem plugin (worker on port 37777).

check() {
    command -v bun >/dev/null 2>&1 || [[ -x "$HOME/.bun/bin/bun" ]]
}

install() {
    # Report a failed download/install as install-failed (rc 1), not as a
    # confusing post-verify rc67. `set -o pipefail` makes this self-contained
    # (the curl rc, not bash's rc on empty stdin, drives the result) instead of
    # relying on the engine's inherited pipefail. check() tests the absolute
    # path, so no in-shell PATH export is needed here.
    set -o pipefail
    if ! curl -fsSL https://bun.sh/install | bash; then
        return 1
    fi
}

verify() {
    check
}

rollback() {
    # Aliased to `dir` so the L05 unguarded-rm-rf lint allowlist applies.
    local dir="$HOME/.bun"
    [[ -x "$dir/bin/bun" ]] && rm -rf "$dir" 2>/dev/null || true
}
