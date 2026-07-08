#!/usr/bin/env bash
# Interactive atuin login (cross-machine history). Skipped in NON_INTERACTIVE
# or when ATUIN_LOGIN_AUTO=0.

# Audit 2026-06-03 (path-fragility): on WSL atuin lives in ~/.atuin/bin (official
# curl|sh installer) which is NOT on the engine item-subshell PATH, so a bare
# `command -v atuin` misses and the login feature silently never runs. Prepend
# the install dir so the bare `atuin` calls below resolve.
case ":$PATH:" in *":$HOME/.atuin/bin:"*) ;; *) PATH="$HOME/.atuin/bin:$PATH" ;; esac

check() {
    command -v atuin >/dev/null 2>&1 || [[ -x "$HOME/.atuin/bin/atuin" ]] || return 0
    # Codex review 2026-05-19 (D-F001): install() returns 0 (success) on
    # 3 skip conditions (opt-out, non-interactive, no TTY). check()/verify
    # must mirror those — otherwise verify falls through to `atuin status`
    # which still fails, and the engine treats the documented advisory
    # deferral as install failure.
    [[ "${ATUIN_LOGIN_AUTO:-1}" == "1" ]] || return 0
    [[ "${NON_INTERACTIVE:-0}" != "1" ]] || return 0
    [[ -t 0 ]] || return 0
    atuin status >/dev/null 2>&1
}

install() {
    command -v atuin >/dev/null 2>&1 || [[ -x "$HOME/.atuin/bin/atuin" ]] || return 0
    if [[ "${ATUIN_LOGIN_AUTO:-1}" != "1" ]]; then
        echo "[atuin-login] ATUIN_LOGIN_AUTO=0 — skipping inline login. Run 'atuin login' when ready." >&2
        return 0
    fi
    if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
        echo "[atuin-login] non-interactive — skipping inline login. Run 'atuin login' when ready." >&2
        return 0
    fi
    if [[ ! -t 0 ]]; then
        echo "[atuin-login] no controlling TTY — skipping inline login. Run 'atuin login' when ready." >&2
        return 0
    fi
    atuin login </dev/tty \
        || echo "[atuin-login] login did not complete (user cancelled or OAuth failed). Re-run 'atuin login' to retry." >&2
}

verify() {
    check
}

repair() { install; }

rollback() {
    :
}
