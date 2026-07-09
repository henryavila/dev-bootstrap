#!/usr/bin/env bash
# Frozen pre-fix fixture: verify() mirrors presence checks and composer only,
# so an active orphan INI warning is never observed.

check() {
    return 0
}

verify() {
    check || return 1
    composer --version >/dev/null 2>&1
}
