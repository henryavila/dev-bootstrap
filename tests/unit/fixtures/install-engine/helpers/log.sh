#!/usr/bin/env bash
# Minimal log.sh helpers (subset of C19 spec).
info()   { printf '\033[36m[info]\033[0m  %s\n' "$*" >&2; }
notice() { printf '\033[34m[notice]\033[0m  %s\n' "$*" >&2; }
ok()     { printf '\033[32m[ok]\033[0m  %s\n' "$*" >&2; }
warn()   { printf '\033[33m[warn]\033[0m  %s\n' "$*" >&2; }
err()    { printf '\033[31m[err]\033[0m  %s\n' "$*" >&2; }
