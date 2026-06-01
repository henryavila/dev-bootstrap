#!/usr/bin/env bash
# Custom installer: Bun runtime.
# Installs to ~/.bun/bin/bun via the official installer. Required by the
# claude-mem plugin (worker on port 37777).

check() {
    command -v bun >/dev/null 2>&1 || [[ -x "$HOME/.bun/bin/bun" ]]
}

install() {
    curl -fsSL https://bun.sh/install | bash
    # Make immediately verifiable in this shell.
    PATH="$HOME/.bun/bin:$PATH"; export PATH
}

verify() {
    check
}

rollback() {
    # Aliased to `dir` so the L05 unguarded-rm-rf lint allowlist applies.
    local dir="$HOME/.bun"
    [[ -x "$dir/bin/bun" ]] && rm -rf "$dir" 2>/dev/null || true
}
