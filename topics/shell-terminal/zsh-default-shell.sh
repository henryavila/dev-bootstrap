#!/usr/bin/env bash
# Make zsh the default login shell + detect & surface mismatches.
# Honors CHSH_AUTO=0 (skip auto attempt). NON_INTERACTIVE=1 skips the
# /dev/tty interactive fallback. Rich UX from the 2026-04-22 session
# preserved verbatim where possible.

_has_ctty() {
    : </dev/tty >/dev/null 2>&1
}

_current_shell_from_dir_service() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}'
    else
        getent passwd "$USER" | cut -d: -f7
    fi
}

check() {
    [[ "${CHSH_AUTO:-1}" == "1" ]] || return 0
    command -v zsh >/dev/null 2>&1 || return 0
    local zsh_bin current
    zsh_bin="$(command -v zsh)"
    current="$(_current_shell_from_dir_service)"
    [[ "$current" == "$zsh_bin" ]]
}

install() {
    [[ "${CHSH_AUTO:-1}" == "1" ]] || return 0
    command -v zsh >/dev/null 2>&1 || return 0
    # Do not change the login shell until mesh ~/.zshrc is deployed. A missing
    # or stock zshrc means Windows Terminal / wsl.exe starts zsh without
    # ~/.zshrc.d — fzf keybindings then exist only in bash (Debian's
    # bash-completion package). Re-run after shell-fragments.
    if [[ ! -f "$HOME/.zshrc" ]] || ! grep -q 'zshrc.d' "$HOME/.zshrc"; then
        echo "[zsh-default-shell] ~/.zshrc is not mesh-managed yet (does not load zshrc.d) — not changing login shell"
        return 0
    fi
    local zsh_bin passwd_shell
    zsh_bin="$(command -v zsh)"

    # Add to /etc/shells if missing (brew-zsh on mac in particular).
    if ! grep -qxF "$zsh_bin" /etc/shells 2>/dev/null; then
        echo "$zsh_bin" | sudo tee -a /etc/shells >/dev/null 2>&1 || true
    fi

    local chsh_ok=0
    # Tier 1: sudo -n chsh (no prompt; relies on cached sudo ticket)
    if sudo -n chsh -s "$zsh_bin" "$USER" 2>/dev/null; then
        chsh_ok=1
    elif [[ "$(uname -s)" != "Darwin" ]]; then
        # Tier 2 (Linux only): sudo -n usermod -s as last automated path.
        # usermod is the only command that survives some LDAP/SSSD setups
        # where chsh refuses by design.
        if sudo -n usermod -s "$zsh_bin" "$USER" 2>/dev/null; then
            chsh_ok=1
        fi
    fi

    # Tier 3: interactive sudo chsh fallback (only if a controlling TTY exists
    # AND user hasn't opted out via NON_INTERACTIVE=1). Long topics outlast
    # the sudo cache (default 5-15min), so we need an explicit interactive
    # path here.
    if [[ "$chsh_ok" -eq 0 ]] \
        && _has_ctty \
        && [[ "${NON_INTERACTIVE:-0}" != "1" ]]; then
        if sudo chsh -s "$zsh_bin" "$USER" </dev/tty; then
            chsh_ok=1
        fi
    fi

    if [[ "$chsh_ok" -eq 0 ]]; then
        # Distinguish "no TTY / non-interactive" from "account managed
        # externally" (LDAP/SSSD on Linux, MDM/directory on Mac).
        if [[ "$(uname -s)" == "Darwin" ]]; then
            echo "[zsh-default-shell] chsh refused — account may be MDM/directory-managed."
            echo "[zsh-default-shell]   workaround: ask sysadmin to set shell to $zsh_bin, OR"
            echo "[zsh-default-shell]   set the shell yourself via System Settings → Users & Groups."
        else
            echo "[zsh-default-shell] chsh refused — account may be managed externally (LDAP/SSSD)."
            echo "[zsh-default-shell]   workaround: ask sysadmin to set shell to $zsh_bin, OR"
            echo "[zsh-default-shell]   set per-session via 'exec $zsh_bin' in your shell rc."
        fi
    fi

    # Detect $SHELL ≠ passwd mismatch in the current session. Even when chsh
    # succeeds, the CURRENT shell instance keeps the old $SHELL (set at login
    # by the parent shell from passwd). The user must reconnect to pick up
    # the new shell. tmux complicates this: tmux's server caches its own
    # SHELL at first launch and propagates that to every new pane until
    # killed.
    passwd_shell="$(_current_shell_from_dir_service)"
    if [[ -n "$passwd_shell" ]] && [[ "${SHELL:-}" != "$passwd_shell" ]]; then
        echo "[zsh-default-shell] mismatch: \$SHELL=${SHELL:-unset} != passwd_shell=$passwd_shell"
        echo "[zsh-default-shell]   to pick up the new shell, exit this ssh/mosh session and reconnect."
        if command -v tmux >/dev/null 2>&1; then
            local tmux_shell
            tmux_shell="$(tmux show-environment -g SHELL 2>/dev/null | sed 's/^SHELL=//' || true)"
            if [[ -n "$tmux_shell" ]] && [[ "$tmux_shell" != "$passwd_shell" ]]; then
                echo "[zsh-default-shell]   tmux server is also caching SHELL=$tmux_shell — run 'tmux kill-server'"
                echo "[zsh-default-shell]   to drop all sessions and re-open with the new shell."
            fi
        fi
    fi
}

verify() {
    [[ "${CHSH_AUTO:-1}" == "1" ]] || return 0
    command -v zsh >/dev/null 2>&1 || return 0
    local zsh_bin current
    zsh_bin="$(command -v zsh)"
    current="$(_current_shell_from_dir_service)"
    if [[ "$current" == "$zsh_bin" ]]; then
        return 0
    fi
    # Codex review 2026-05-19 (D-F005 / F-F001): on a managed-externally
    # account (LDAP/SSSD on Linux, MDM/directory on Mac), chsh refuses by
    # design. install() already emits the advisory; verify() must not fail
    # — that would route the item through engine rollback as a "broken
    # install" when it's a documented user-action-required state.
    return 0
}

repair() { install; }

rollback() {
    :
}
