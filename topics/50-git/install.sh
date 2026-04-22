#!/usr/bin/env bash
# 50-git: apply gitconfig.keys to ~/.gitconfig, never overwriting [user]/[credential].
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

if ! command -v git >/dev/null 2>&1; then
    fail "git not found (topic 00-core should have installed it)"
    exit 1
fi

keys_file="$HERE/data/gitconfig.keys"
if [[ ! -f "$keys_file" ]]; then
    fail "missing $keys_file"
    exit 1
fi

# Apply each "key=value" line via git config --global
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line// }" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    key="${line%%=*}"
    value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"

    # Never touch user.* or credential.*
    case "$key" in
        user.*|credential.*)
            warn "skip $key (preserved from existing config)"
            continue
            ;;
    esac

    current="$(git config --global --get "$key" 2>/dev/null || true)"
    if [[ "$current" == "$value" ]]; then
        ok "$key already = $value"
    else
        info "git config --global $key '$value'"
        git config --global "$key" "$value"
    fi
done < "$keys_file"

# Apply GIT_NAME/GIT_EMAIL from env var only if user.name/user.email not set
current_name="$(git config --global --get user.name 2>/dev/null || true)"
current_email="$(git config --global --get user.email 2>/dev/null || true)"

if [[ -z "$current_name" ]] && [[ -n "${GIT_NAME:-}" ]]; then
    info "git config --global user.name '$GIT_NAME'"
    git config --global user.name "$GIT_NAME"
elif [[ -n "$current_name" ]]; then
    ok "user.name preserved: $current_name"
fi

if [[ -z "$current_email" ]] && [[ -n "${GIT_EMAIL:-}" ]]; then
    info "git config --global user.email '$GIT_EMAIL'"
    git config --global user.email "$GIT_EMAIL"
elif [[ -n "$current_email" ]]; then
    ok "user.email preserved: $current_email"
fi

# ─── GPG commit signing (opt-in) ──────────────────────────────────────
# Activated by exporting GPG_SIGN=1 before bootstrap. GPG_KEY_ID is
# optional — if absent, the first secret key from `gpg --list-secret-keys`
# is picked automatically. Falls through with a clear message if no key
# is available, so the user knows exactly what to do (`gpg --gen-key`).
if [[ "${GPG_SIGN:-0}" == "1" ]]; then
    if ! command -v gpg >/dev/null 2>&1; then
        warn "GPG_SIGN=1 but gpg not installed — skipping signing config"
    else
        signing_key="${GPG_KEY_ID:-}"
        if [[ -z "$signing_key" ]]; then
            # Pick the first usable secret key (long format, keyid only).
            signing_key="$(gpg --list-secret-keys --keyid-format=long 2>/dev/null \
                | awk '/^sec/ {split($2, a, "/"); print a[2]; exit}')"
        fi

        if [[ -z "$signing_key" ]]; then
            warn "GPG_SIGN=1 but no secret key found — generate one with:"
            warn "    gpg --full-generate-key        # RSA 4096, your git email"
            warn "    gpg --list-secret-keys --keyid-format=long"
            warn "  then re-run with GPG_KEY_ID=<id> bash bootstrap.sh"
        else
            info "enabling commit + tag signing with key $signing_key"
            git config --global user.signingkey "$signing_key"
            git config --global commit.gpgsign true
            git config --global tag.gpgsign true
            # gpg.program: default works on most systems, but on macOS with
            # pinentry-mac the full brew path is safer. Only set if non-default.
            if [[ -n "${BREW_PREFIX:-}" ]] && [[ -x "$BREW_PREFIX/bin/gpg" ]]; then
                git config --global gpg.program "$BREW_PREFIX/bin/gpg"
            fi
            ok "GPG signing enabled (key $signing_key)"
        fi
    fi
else
    # No-op — don't mention unless explicitly activated.
    :
fi

ok "50-git done"
