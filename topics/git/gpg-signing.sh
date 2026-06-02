#!/usr/bin/env bash
# Custom installer: GPG commit/tag signing (the git/gpg-signing bundle).
# Selecting the bundle IS the activation gate (v2 — no GPG_SIGN env guard).
# GPG_KEY_ID is optional — first secret key from `gpg --list-secret-keys`
# if absent.

check() {
    # Git already configured to sign with a key?
    local key
    key="$(git config --global --get user.signingkey 2>/dev/null || true)"
    [[ -n "$key" ]] \
        && [[ "$(git config --global --get commit.gpgsign 2>/dev/null)" == "true" ]]
}

# Echo the GPG secret key to sign with (GPG_KEY_ID, else the first `sec` key),
# or empty when gpg is missing / no secret key exists. Single source of truth
# for install() and verify() so they agree on "is there anything to configure".
_resolve_signing_key() {
    command -v gpg >/dev/null 2>&1 || { echo ""; return; }
    if [[ -n "${GPG_KEY_ID:-}" ]]; then echo "$GPG_KEY_ID"; return; fi
    gpg --list-secret-keys --keyid-format=long 2>/dev/null \
        | awk '/^sec/ {split($2, a, "/"); print a[2]; exit}'
}

install() {
    if ! command -v gpg >/dev/null 2>&1; then
        echo "[gpg-signing] gpg not installed — skipping" >&2
        return 0
    fi
    local signing_key; signing_key="$(_resolve_signing_key)"
    if [[ -z "$signing_key" ]]; then
        echo "[gpg-signing] no secret key found — signing left unconfigured (opt-in, not a failure)." >&2
        echo "  Generate one and re-run to enable it:" >&2
        echo "    gpg --full-generate-key   # RSA 4096" >&2
        echo "    gpg --list-secret-keys --keyid-format=long" >&2
        echo "  then re-run (optionally GPG_KEY_ID=<id> to pick a specific key)." >&2
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
    # Opt-in bundle: when there's no key material, install() skips by design, so
    # "signing not configured" is success here — not a failure that aborts the
    # whole run (the prior `check`-only verify exited rc=67 on select-all).
    [[ -z "$(_resolve_signing_key)" ]] && return 0
    check
}

rollback() {
    # Don't touch signing config — user may rely on it from other sources.
    :
}
