#!/usr/bin/env bash
# Make zsh the default login shell (brew-zsh on mac, system zsh on wsl).
# Both platforms: requires sudo for chsh. Mac additionally needs the
# brew-zsh path appended to /etc/shells. CHSH_AUTO=0 skips silently.

check() {
    [[ "${CHSH_AUTO:-1}" == "1" ]] || return 0
    command -v zsh >/dev/null 2>&1 || return 0
    local zsh_bin current
    zsh_bin="$(command -v zsh)"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        current="$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}')"
    else
        current="$(getent passwd "$USER" | cut -d: -f7)"
    fi
    [[ "$current" == "$zsh_bin" ]]
}

install() {
    [[ "${CHSH_AUTO:-1}" == "1" ]] || return 0
    command -v zsh >/dev/null 2>&1 || return 0
    local zsh_bin
    zsh_bin="$(command -v zsh)"

    # Add to /etc/shells if missing (brew-zsh on mac in particular).
    if ! grep -qxF "$zsh_bin" /etc/shells 2>/dev/null; then
        echo "$zsh_bin" | sudo tee -a /etc/shells >/dev/null 2>&1 || true
    fi

    if sudo -n chsh -s "$zsh_bin" "$USER" 2>/dev/null; then
        return 0
    elif [[ -t 0 ]] && [[ "${NON_INTERACTIVE:-0}" != "1" ]]; then
        sudo chsh -s "$zsh_bin" "$USER" \
            || echo "[zsh-default-shell] chsh failed — set manually with 'sudo chsh -s $zsh_bin $USER'" >&2
    fi
}

verify() {
    check
}

rollback() {
    :
}
