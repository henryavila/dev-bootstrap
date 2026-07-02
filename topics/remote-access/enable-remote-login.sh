#!/usr/bin/env bash
# Custom installer: enable macOS Remote Login (sshd).
#
# Detection model (2026-05-28): replaced `sudo systemsetup -getremotelogin`
# with `launchctl print-disabled system`, which reads launchd's
# user-override database without sudo. The output line
#   "com.openssh.sshd" => enabled    (or disabled)
# is the same authoritative signal that the Sharing prefpane reads.
# Verified live on macOS — works as a non-admin user with zero prompts.
#
# The install side still requires sudo because flipping the Remote Login
# toggle is a privileged system mutation; there is no documented
# non-sudo path for that. Sudo there is correct friction (user opted in).

check() {
    # Capture then bash-match — NOT `launchctl print-disabled | grep -q`: under the
    # engine's pipefail, grep -q closing the pipe early SIGPIPE-kills launchctl (141)
    # → a false "disabled". See feedback_engine_pipefail_grep_q_broken_pipe (lint L21).
    local _lc re; _lc="$(launchctl print-disabled system 2>/dev/null)"
    re='"com\.openssh\.sshd"[[:space:]]*=>[[:space:]]*enabled'
    [[ "$_lc" =~ $re ]]
}

install() {
    sudo systemsetup -setremotelogin on
}

verify() {
    check
}

repair() { install; }

rollback() {
    # Don't auto-disable — the user may have enabled it for other reasons.
    :
}
