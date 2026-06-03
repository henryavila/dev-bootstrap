#!/usr/bin/env bash
# NPM global prefix (~/.npm-global). Gated in v2 by the languages/node bundle's
# `npm-global-prefix` toggle (when: option.npm-global-prefix) — the engine only
# runs this item when the toggle is on, so there is no env guard in the script.

NPM_GLOBAL_BIN="$HOME/.npm-global/bin"
NPM_GLOBAL_PREFIX_NPMRC='prefix=${HOME}/.npm-global'
NPM_GLOBAL_FRAGMENT_NAME="20-npm-global.sh"

NPM_GLOBAL_FRAGMENT_MARKER='# Managed by topic 10-languages: optional npm global prefix.'

check() {
    [[ -f "$HOME/.npmrc" ]] || return 1
    grep -qxF "$NPM_GLOBAL_PREFIX_NPMRC" "$HOME/.npmrc" || return 1
    # install() also writes PATH fragments to both rc.d dirs; require them too so
    # a removed fragment triggers a real re-install (Wave 4 idempotency-asymmetry).
    local f
    for f in "$HOME/.bashrc.d/$NPM_GLOBAL_FRAGMENT_NAME" \
             "$HOME/.zshrc.d/$NPM_GLOBAL_FRAGMENT_NAME"; do
        [[ -f "$f" ]] || return 1
        grep -qxF "$NPM_GLOBAL_FRAGMENT_MARKER" "$f" || return 1
    done
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
        # CP4 chunk C finding C-F-005: counter-suffix on collision.
        local ts backup i
        ts="$(date +%Y%m%d-%H%M%S)"
        backup="${npmrc}.bak-${ts}"
        i=1
        while [[ -e "$backup" ]]; do
            backup="${npmrc}.bak-${ts}-${i}"
            i=$((i + 1))
            (( i > 9999 )) && backup="${npmrc}.bak-${ts}-$$.${RANDOM}" && break
        done
        cp -p "$npmrc" "$backup"
    fi
    mv "$tmp" "$npmrc"
}

install() {
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
