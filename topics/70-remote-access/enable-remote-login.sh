#!/usr/bin/env bash
# Custom installer: enable macOS Remote Login (sshd).

check() {
    sudo systemsetup -getremotelogin 2>/dev/null | grep -qi 'on'
}

install() {
    sudo systemsetup -setremotelogin on
}

verify() {
    check
}

rollback() {
    # Don't auto-disable — the user may have enabled it for other reasons.
    :
}
