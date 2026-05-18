#!/usr/bin/env bash
# NPM global prefix (~/.npm-global) — gated by INCLUDE_NPM_GLOBAL=1.

NPM_GLOBAL_BIN="$HOME/.npm-global/bin"
NPM_GLOBAL_PREFIX_NPMRC='prefix=${HOME}/.npm-global'
NPM_GLOBAL_FRAGMENT_NAME="20-npm-global.sh"

check() {
    [[ "${INCLUDE_NPM_GLOBAL:-0}" == "1" ]] || return 0
    [[ -f "$HOME/.npmrc" ]] || return 1
    grep -qxF "$NPM_GLOBAL_PREFIX_NPMRC" "$HOME/.npmrc"
}

_path_fragment() {
    local dst="$1" tmp
    mkdir -p "$(dirname "$dst")"
    tmp=$(mktemp "${dst}.npm.XXXXXX") || return 1
    chmod 0644 "$tmp"
    cat > "$tmp" <<'FRAG_EOF'
# Managed by topic 10-languages: optional npm global prefix.
npm_global_bin="$HOME/.npm-global/bin"
case ":$PATH:" in
    *":$npm_global_bin:"*) ;;
    *) [ -d "$npm_global_bin" ] && export PATH="$npm_global_bin:$PATH" ;;
esac
unset npm_global_bin
FRAG_EOF
    if [[ -f "$dst" ]] && cmp -s "$tmp" "$dst"; then
        rm -f "$tmp"; return 0
    fi
    mv "$tmp" "$dst"
}

_ensure_npmrc() {
    local npmrc="$HOME/.npmrc" tmp
    if [[ -f "$npmrc" ]] && grep -qxF "$NPM_GLOBAL_PREFIX_NPMRC" "$npmrc"; then return 0; fi
    tmp=$(mktemp "${npmrc}.npm.XXXXXX") || return 1
    chmod 0600 "$tmp"
    if [[ -f "$npmrc" ]]; then
        awk '/^[[:space:]]*prefix[[:space:]]*=/ { next } { print }' "$npmrc" > "$tmp"
    fi
    if [[ -s "$tmp" ]] && [[ -n "$(tail -c1 "$tmp")" ]]; then
        printf '\n' >> "$tmp"
    fi
    printf '%s\n' "$NPM_GLOBAL_PREFIX_NPMRC" >> "$tmp"
    if [[ -f "$npmrc" ]] && cmp -s "$tmp" "$npmrc"; then rm -f "$tmp"; return 0; fi
    if [[ -f "$npmrc" ]]; then
        cp -p "$npmrc" "${npmrc}.bak-$(date +%Y%m%d-%H%M%S)"
    fi
    mv "$tmp" "$npmrc"
}

install() {
    [[ "${INCLUDE_NPM_GLOBAL:-0}" == "1" ]] || return 0
    mkdir -p "$NPM_GLOBAL_BIN"
    _ensure_npmrc
    _path_fragment "$HOME/.bashrc.d/$NPM_GLOBAL_FRAGMENT_NAME"
    _path_fragment "$HOME/.zshrc.d/$NPM_GLOBAL_FRAGMENT_NAME"
}

verify() { check; }

rollback() {
    rm -f "$HOME/.bashrc.d/$NPM_GLOBAL_FRAGMENT_NAME" \
          "$HOME/.zshrc.d/$NPM_GLOBAL_FRAGMENT_NAME"
}
