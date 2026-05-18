#!/usr/bin/env bash
# Interactive atuin login (cross-machine history). Skipped in NON_INTERACTIVE
# or when ATUIN_LOGIN_AUTO=0.

check() {
    command -v atuin >/dev/null 2>&1 || return 0
    atuin status >/dev/null 2>&1
}

install() {
    command -v atuin >/dev/null 2>&1 || return 0
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

rollback() {
    :
}
