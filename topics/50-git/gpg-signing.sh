#!/usr/bin/env bash
# Custom installer: opt-in GPG commit/tag signing.
# Activated by exporting GPG_SIGN=1 before bootstrap. GPG_KEY_ID is
# optional — first secret key from `gpg --list-secret-keys` if absent.

check() {
    # Not activated → "nothing to do" → idempotent pass.
    [[ "${GPG_SIGN:-0}" == "1" ]] || return 0
    # Activated → check git already configured to sign with a key.
    local key
    key="$(git config --global --get user.signingkey 2>/dev/null || true)"
    [[ -n "$key" ]] \
        && [[ "$(git config --global --get commit.gpgsign 2>/dev/null)" == "true" ]]
}

install() {
    [[ "${GPG_SIGN:-0}" == "1" ]] || return 0
    if ! command -v gpg >/dev/null 2>&1; then
        echo "[gpg-signing] GPG_SIGN=1 but gpg not installed — skipping" >&2
        return 0
    fi
    local signing_key="${GPG_KEY_ID:-}"
    if [[ -z "$signing_key" ]]; then
        signing_key="$(gpg --list-secret-keys --keyid-format=long 2>/dev/null \
            | awk '/^sec/ {split($2, a, "/"); print a[2]; exit}')"
    fi
    if [[ -z "$signing_key" ]]; then
        echo "[gpg-signing] GPG_SIGN=1 but no secret key. Generate with:" >&2
        echo "    gpg --full-generate-key   # RSA 4096" >&2
        echo "    gpg --list-secret-keys --keyid-format=long" >&2
        echo "  then re-run with GPG_KEY_ID=<id>." >&2
        return 0
    fi
    git config --global user.signingkey "$signing_key"
    git config --global commit.gpgsign true
    git config --global tag.gpgsign true
    if [[ -n "${BREW_PREFIX:-}" ]] && [[ -x "$BREW_PREFIX/bin/gpg" ]]; then
        git config --global gpg.program "$BREW_PREFIX/bin/gpg"
    fi
}

verify() {
    check
}

rollback() {
    # Don't touch signing config — user may rely on it from other sources.
    :
}
