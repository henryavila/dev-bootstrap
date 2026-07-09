#!/usr/bin/env bash
# Frozen pre-fix fixture: a PECL build failure is warned but returns success.

pecl_install_for_version_linux() {
    local ver="$1" ext="$2"
    warn "PHP $ver: pecl install $ext failed (exit=42, .so not at /fixture/${ext}.so)"
    return 0
}
