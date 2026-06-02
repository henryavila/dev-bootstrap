#!/usr/bin/env bash
# shellcheck shell=bash
# secrets-crypt.sh — git-crypt wiring for the secrets layer.
#
# Tier-2 secrets live ENCRYPTED in the identity repo and are decrypted into the
# working tree by git-crypt's clean/smudge filter, so install.sh/deploy_one see
# cleartext and need no decryption logic.
#
# Encryption is governed by ONE global rule in the repo-root .gitattributes, so a
# human never marks files one by one — every file under secrets/ is encrypted,
# present and future, EXCEPT the manifest (cleartext registry, no secrets) and
# .gitattributes itself:
#
#     secrets/** filter=git-crypt diff=git-crypt
#     secrets/manifest.yaml !filter !diff
#     secrets/.gitattributes !filter !diff
#
# Public API (sourced, not executed):
#   secrets_crypt_available                rc0 if git-crypt is installed
#   secrets_crypt_install                  install git-crypt (brew/apt); rc0 ok
#   secrets_crypt_initialized <repo>       rc0 if git-crypt is set up in <repo>
#   secrets_crypt_unlocked <repo>          rc0 if the key is present (decryptable)
#   secrets_crypt_init <repo> <keyout>     git-crypt init + export-key → <keyout>
#   secrets_crypt_unlock <repo> <keyfile>  git-crypt unlock <keyfile>
#   secrets_crypt_attr_ensure <repo>       ensure the canonical .gitattributes block
#   secrets_crypt_attr_ok <repo>          rc0 if the block is present + correct
#   secrets_crypt_guard <repo>            FAIL-CLOSED pre-commit guard: refuse if
#                                          any staged secrets/ file would commit in
#                                          cleartext. rc0 safe, rc1 unsafe (block).
#
# Bash 3.2 floor (macOS /bin/bash). git-crypt calls are thin wrappers; the file
# logic (attr block, detection) is pure so it is unit-testable without git-crypt.

[ -n "${_SECRETS_CRYPT_LOADED:-}" ] && return 0
_SECRETS_CRYPT_LOADED=1

_SC_ATTR_MARKER="# mesh-secrets: git-crypt (managed — do not edit between markers)"
_SC_ATTR_END="# mesh-secrets: end"

# --- git-crypt availability + install ---------------------------------------

secrets_crypt_available() { command -v git-crypt >/dev/null 2>&1; }

# Install git-crypt via the host package manager. Returns 0 if available after.
secrets_crypt_install() {
    secrets_crypt_available && return 0
    if command -v brew >/dev/null 2>&1; then
        brew install git-crypt >&2 || return 1
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y git-crypt >&2 || return 1
    else
        echo "secrets-crypt: no supported package manager (brew/apt) to install git-crypt" >&2
        return 1
    fi
    secrets_crypt_available
}

# --- repo state detection ----------------------------------------------------

# git-crypt is set up in <repo> once `git-crypt init` has run (creates
# .git/git-crypt/). This is true on the machine that initialized it.
secrets_crypt_initialized() {
    local repo="$1"
    [ -d "$repo/.git/git-crypt" ]
}

# The repo is "unlocked" (can decrypt) when the symmetric key is present.
# After a fresh clone the key is absent until `git-crypt unlock`.
secrets_crypt_unlocked() {
    local repo="$1"
    [ -f "$repo/.git/git-crypt/keys/default" ]
}

# --- init / unlock -----------------------------------------------------------

# Initialize git-crypt in <repo> and export the symmetric key to <keyout>.
# <keyout> is the ROOT secret — the caller must tell the user to store it in a
# password manager and must NOT leave it inside the repo.
secrets_crypt_init() {
    local repo="$1" keyout="$2"
    secrets_crypt_available || { echo "secrets-crypt: git-crypt not installed" >&2; return 1; }
    [ -n "$keyout" ] || { echo "secrets-crypt: init needs a key output path" >&2; return 1; }
    if secrets_crypt_initialized "$repo"; then
        echo "secrets-crypt: already initialized in $repo" >&2
        return 0
    fi
    ( cd "$repo" && git-crypt init ) >&2 || return 1
    ( cd "$repo" && git-crypt export-key "$keyout" ) >&2 || return 1
    chmod 600 "$keyout" 2>/dev/null || true
}

secrets_crypt_unlock() {
    local repo="$1" keyfile="$2"
    secrets_crypt_available || { echo "secrets-crypt: git-crypt not installed" >&2; return 1; }
    [ -f "$keyfile" ] || { echo "secrets-crypt: key file not found: $keyfile" >&2; return 1; }
    ( cd "$repo" && git-crypt unlock "$keyfile" ) >&2
}

# --- .gitattributes management (pure file logic) -----------------------------

# Echo the canonical managed block.
_sc_attr_block() {
    printf '%s\n' "$_SC_ATTR_MARKER"
    printf '%s\n' "secrets/** filter=git-crypt diff=git-crypt"
    printf '%s\n' "secrets/manifest.yaml !filter !diff"
    printf '%s\n' "secrets/.gitattributes !filter !diff"
    printf '%s\n' "$_SC_ATTR_END"
}

# rc0 if the repo-root .gitattributes already contains the managed block.
secrets_crypt_attr_ok() {
    local repo="$1" ga="$1/.gitattributes"
    [ -f "$ga" ] || return 1
    grep -qF "$_SC_ATTR_MARKER" "$ga" 2>/dev/null || return 1
    grep -qF "secrets/** filter=git-crypt diff=git-crypt" "$ga" 2>/dev/null
}

# Ensure the managed block is present (idempotent; appends if missing).
secrets_crypt_attr_ensure() {
    local repo="$1" ga="$1/.gitattributes"
    secrets_crypt_attr_ok "$repo" && return 0
    if [ -f "$ga" ] && grep -qF "$_SC_ATTR_MARKER" "$ga" 2>/dev/null; then
        # Stale/partial block — refuse to silently double-append.
        echo "secrets-crypt: $ga has a mesh-secrets marker but the rule is wrong; fix by hand" >&2
        return 1
    fi
    {
        [ -f "$ga" ] && [ -s "$ga" ] && printf '\n'
        _sc_attr_block
    } >> "$ga" || return 1
}

# --- pre-commit guard (FAIL-CLOSED) -----------------------------------------

# Refuse the commit if any staged file under secrets/ (other than the cleartext
# manifest/.gitattributes) would land in cleartext. This is the catastrophic
# leak preventer. rc0 = safe to commit, rc1 = block.
secrets_crypt_guard() {
    local repo="$1"
    # Files staged under secrets/ in this commit, minus the always-cleartext
    # ones (the registry manifest + .gitattributes carry no secrets).
    local staged must_encrypt="" f
    staged="$( cd "$repo" && git diff --cached --name-only -- 'secrets/' 2>/dev/null )"
    for f in $staged; do
        case "$f" in
            secrets/manifest.yaml|secrets/.gitattributes) continue ;;
            *) must_encrypt="$must_encrypt $f" ;;
        esac
    done
    # Only cleartext files (or nothing) staged → safe, no git-crypt needed.
    [ -n "${must_encrypt# }" ] || return 0

    # Real secrets staged ⇒ the encryption rule must exist...
    if ! secrets_crypt_attr_ok "$repo"; then
        echo "secrets-crypt: GUARD — secrets/ files staged but .gitattributes git-crypt rule is missing." >&2
        echo "  Run: mesh secret init   (or fix the repo-root .gitattributes)" >&2
        return 1
    fi
    # ...and git-crypt must be installed + initialized, or the clean filter
    # never runs and the file commits in cleartext.
    if ! secrets_crypt_available; then
        echo "secrets-crypt: GUARD — git-crypt is not installed; staged secrets would commit in cleartext." >&2
        return 1
    fi
    if ! secrets_crypt_initialized "$repo"; then
        echo "secrets-crypt: GUARD — git-crypt not initialized in this repo; run 'mesh secret init' or 'mesh secret unlock'." >&2
        return 1
    fi
    # Authoritative check: git-crypt status must report every real secret as
    # encrypted.
    local line
    for f in $must_encrypt; do
        line="$( cd "$repo" && git-crypt status -- "$f" 2>/dev/null )"
        case "$line" in
            *"not encrypted"*|"")
                echo "secrets-crypt: GUARD — '$f' is NOT encrypted (would leak in cleartext). Commit blocked." >&2
                return 1
                ;;
        esac
    done
    return 0
}
