#!/usr/bin/env bash
# Frozen pre-fix fixture: mac PECL lines are parsed, and a helper exists, but
# install() never calls the helper for each PHP version/extension pair.

PECL_LINES=("redis::")

pecl_install_for_mac() {
    : > "${SENT_DIR:?}/mac-helper-called"
}

install() {
    local line ext
    for line in "${PECL_LINES[@]}"; do
        IFS=':' read -r ext _ _ <<< "$line"
        : > "${SENT_DIR:?}/mac-ext-${ext}-seen"
    done
}
