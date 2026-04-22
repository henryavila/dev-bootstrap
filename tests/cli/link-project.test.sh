#!/usr/bin/env bash
# tests/cli/link-project.test.sh — behavior tests for link-project.
#
# The hard-destructive paths (writing to /etc/nginx, sudo reload) are
# NOT exercised here — those need root and a real nginx. We focus on
# read-only branches:
#   - --help / no args prints usage, exits 0
#   - default mode with non-existent project → exits != 0 with clear msg
#   - default mode with valid project dir + public/ → exits 0, prints URL
#   - --list with no sites enabled → prints "(none)" branch

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

LINK="$REPO_ROOT/topics/60-web-stack/templates/bin/link-project.template"
assert_file_exists "$LINK"

echo "--help / no args exit 0 + prints usage"
assert_exit_code 0 "bash '$LINK' --help"
assert_exit_code 0 "bash '$LINK'"

echo
echo "default mode fails on missing project dir"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CODE_DIR="$tmp/code"
mkdir -p "$CODE_DIR"

out_missing="$(bash "$LINK" missing-proj 2>&1 || true)"
assert_contains "$out_missing" "doesn't exist" "complains about missing dir"

echo
echo "default mode warns when public/ is absent but still exits OK"

mkdir -p "$CODE_DIR/myproj"   # project exists but no public/
out_nopub="$(bash "$LINK" myproj 2>&1 || true)"
assert_contains "$out_nopub" "public" "mentions public/ in warning"
assert_contains "$out_nopub" "served by the catchall" "prints success message"

echo
echo "default mode happy path — project + public/ both exist"

mkdir -p "$CODE_DIR/myproj/public"
out_happy="$(bash "$LINK" myproj 2>&1)"
assert_contains "$out_happy" "https://myproj.localhost" "URL printed"
assert_not_contains "$out_happy" "missing" "no warning about public/ missing"

echo
echo "--list branch when NGINX_ENABLED_DIR is empty → prints (none)"

export NGINX_ENABLED_DIR="$tmp/enabled"
mkdir -p "$NGINX_ENABLED_DIR"
out_list="$(bash "$LINK" --list 2>&1)"
assert_contains "$out_list" "(none" "reports empty state when no sites enabled"

summary
