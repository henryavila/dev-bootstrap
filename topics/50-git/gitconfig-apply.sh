#!/usr/bin/env bash
# Custom installer: apply data/gitconfig.keys to ~/.gitconfig
# (additive set + unset removed keys + env identity defaults).
#
# Never overwrites user.* / credential.* — those are personal.

_apply_keys() {
    local here keys_file line key value current
    here="$1"
    keys_file="$here/data/gitconfig.keys"
    [[ -f "$keys_file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "${line// }" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
        case "$key" in
            user.*|credential.*)
                echo "[gitconfig] skip $key (preserved from existing config)"
                continue
                ;;
        esac
        current="$(git config --global --get "$key" 2>/dev/null || true)"
        if [[ "$current" != "$value" ]]; then
            git config --global "$key" "$value"
        fi
    done < "$keys_file"
}

_unset_removed() {
    local here removed_file key
    here="$1"
    removed_file="$here/data/gitconfig.removed"
    [[ -f "$removed_file" ]] || return 0
    while IFS= read -r key || [[ -n "$key" ]]; do
        key="${key%$'\r'}"
        [[ -z "${key// }" ]] && continue
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
        case "$key" in
            user.*|credential.*) continue ;;
        esac
        if git config --global --get "$key" >/dev/null 2>&1; then
            git config --global --unset "$key" || true
        fi
    done < "$removed_file"
}

_apply_env_identity() {
    local current_name current_email
    current_name="$(git config --global --get user.name 2>/dev/null || true)"
    current_email="$(git config --global --get user.email 2>/dev/null || true)"
    if [[ -z "$current_name" ]] && [[ -n "${GIT_NAME:-}" ]]; then
        git config --global user.name "$GIT_NAME"
    fi
    if [[ -z "$current_email" ]] && [[ -n "${GIT_EMAIL:-}" ]]; then
        git config --global user.email "$GIT_EMAIL"
    fi
}

check() {
    # The keys-apply step is idempotent and cheap, so we treat the topic
    # as "needs install" if data/gitconfig.keys exists at all.
    # (Truly idempotent: re-running just sets each key to its already-correct
    # value, prints nothing useful, exits 0.)
    return 1
}

install() {
    command -v git >/dev/null 2>&1 \
        || { echo "[gitconfig] git not found (00-core should install it)" >&2; return 1; }
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _apply_keys "$here"
    _unset_removed "$here"
    _apply_env_identity
}

verify() {
    # Verify a sentinel key from data/gitconfig.keys made it through.
    # We use init.defaultBranch as a stand-in (commonly set in the file).
    local here sentinel
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    sentinel="$(grep -E '^[^#]' "$here/data/gitconfig.keys" 2>/dev/null | head -1 | cut -d= -f1)"
    [[ -z "$sentinel" ]] && return 0
    git config --global --get "$sentinel" >/dev/null 2>&1
}

rollback() {
    # Don't roll back — user's gitconfig holds personal info we shouldn't touch.
    :
}
