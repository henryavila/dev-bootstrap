#!/usr/bin/env bash
# Custom installer: delegates to the existing 178-LOC interactive
# scripts/setup-identity.sh (gh auth + SSH key + GitHub registration).
# Wrapper avoids rewriting the procedural script during mass migration.

check() {
    # Considered "installed" when gh is authenticated AND an SSH key
    # exists. We don't verify the GitHub-side registration here — that's
    # an interactive concern best left to the procedural script.
    command -v gh >/dev/null 2>&1 \
        && gh auth status >/dev/null 2>&1 \
        && { [[ -f "$HOME/.ssh/id_ed25519" ]] || [[ -f "$HOME/.ssh/id_rsa" ]]; }
}

install() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bash "$here/scripts/setup-identity.sh"
}

verify() {
    check
}

rollback() {
    # Identity setup is irreversible by design (we don't auto-revoke
    # GitHub OAuth tokens or delete SSH keys on rollback). No-op.
    :
}
