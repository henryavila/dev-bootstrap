#!/usr/bin/env bash
# lib/log.sh — output helpers. Source this file; do not execute.
# Respects NO_COLOR env var and non-TTY stdout.

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    _C_RED=$'\033[31m'
    _C_GRN=$'\033[32m'
    _C_YEL=$'\033[33m'
    _C_BLU=$'\033[34m'
    _C_BLD=$'\033[1m'
    _C_RST=$'\033[0m'
else
    _C_RED=""; _C_GRN=""; _C_YEL=""; _C_BLU=""; _C_BLD=""; _C_RST=""
fi

info()   { printf '%s→%s %s\n' "$_C_BLU" "$_C_RST" "$*"; }
ok()     { printf '%s✓%s %s\n' "$_C_GRN" "$_C_RST" "$*"; }
warn()   { printf '%s!%s %s\n' "$_C_YEL" "$_C_RST" "$*" >&2; }
fail()   { printf '%s✗%s %s\n' "$_C_RED" "$_C_RST" "$*" >&2; }
banner() { printf '\n%s== %s ==%s\n' "$_C_BLD" "$*" "$_C_RST"; }
