#!/usr/bin/env bash
# Fake PHP binary that models an active orphan INI: php --ini exits 0 but emits
# the same startup warning class that a dangling extension=*.so line produces.

if [[ -n "${PHP_ORPHAN_SENTINEL:-}" ]]; then
    : > "$PHP_ORPHAN_SENTINEL"
fi

case "${1:-}" in
    --ini)
        printf 'Configuration File (php.ini) Path: /fixture\n'
        printf 'PHP Startup: Unable to load dynamic library redis.so\n' >&2
        exit 0
        ;;
    -m)
        printf 'Core\n'
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
