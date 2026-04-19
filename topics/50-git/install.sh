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

ok "50-git done"
