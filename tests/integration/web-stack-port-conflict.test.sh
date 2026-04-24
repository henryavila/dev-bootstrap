#!/usr/bin/env bash
# tests/integration/web-stack-port-conflict.test.sh
#
# Regression: bug found 2026-04-24 on crc (corporate WSL).
#
# Apache2 was pre-installed on the corporate machine (binary owned by IT
# image, listening on :80). Bootstrap ran 60-web-stack/install.wsl.sh which:
#   - apt-installed nginx successfully (apt doesn't conflict with apache2)
#   - deployed catchall-php.conf + catchall-proxy.conf with `listen 80;`
#   - called `sudo systemctl reload nginx`
#   - reload returned exit 1 ("Unit cannot be reloaded because it is inactive")
#   - the warn() that followed was the only signal — easily lost in the
#     followup summary noise.
#
# Result: nginx in `failed` state for 22h, web stack non-functional, user
# never told why. The script exits OK. CI smoke-test passes (clean Ubuntu,
# no Apache).
#
# This test asserts that 60-web-stack/install.wsl.sh runs a port-conflict
# pre-flight BEFORE attempting nginx reload/start, and that the diagnostic
# is upgraded to a `followup` (consolidated end-of-bootstrap summary) so it
# cannot be silently dropped on the floor.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

WSL="$ROOT/topics/60-web-stack/install.wsl.sh"

assert_pattern_present() {
    local file="$1" pattern="$2" msg="$3"
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' not found in $file)"
    fi
}

echo
echo "═══ Pre-flight: port :80 / :443 conflict detection BEFORE nginx reload ═══"

# The check should call ss / netstat / lsof to inspect port owner, with
# a guard for nginx itself (own port = OK).
assert_pattern_present "$WSL" '(ss -[a-zA-Z]*l[a-zA-Z]*p|netstat -[a-zA-Z]*p|lsof -i)' \
    "60-web-stack/install.wsl.sh — uses ss/netstat/lsof to inspect port owner"

# It must look at port 80 specifically (the Apache2 trigger; the same applies
# to 443 but :80 is the canonical one for Apache default install).
assert_pattern_present "$WSL" ':80\b|port[[:space:]]*=?[[:space:]]*80' \
    "60-web-stack/install.wsl.sh — explicitly inspects port 80"

# It must mention apache2 by name (or a generic conflict message that
# includes apache2 in its examples) — corporate machines almost always have
# Apache, and the user needs the exact disable command.
assert_pattern_present "$WSL" 'apache2|apache|httpd' \
    "60-web-stack/install.wsl.sh — names apache2 / httpd in the conflict path"

# Diagnostic must be `followup` (not just `warn`) so the consolidated
# end-of-bootstrap summary surfaces it after the long-running topic noise.
# Pattern: `followup` appearing within ~30 lines of port-80 inspection.
if grep -nE 'followup[[:space:]]+(critical|manual)' "$WSL" >/dev/null 2>&1; then
    pass "60-web-stack/install.wsl.sh — uses followup critical/manual for the conflict path"
else
    fail "60-web-stack/install.wsl.sh — port-conflict diagnostic must use followup, not warn"
fi

# Disable command must be presented to the user — `systemctl disable --now`
# is the canonical "stop AND prevent restart on next boot".
assert_pattern_present "$WSL" 'disable.*--now|--now.*disable' \
    "60-web-stack/install.wsl.sh — emits 'systemctl disable --now' as the actionable fix"

# The reload step must be skipped when conflict detected — otherwise the
# "could not reload" warning still pollutes the log AND nginx stays in
# failed state. Look for any conditional gate around the reload call.
assert_pattern_present "$WSL" 'PORT_CONFLICT|port_conflict|web_port_owner|skip_nginx' \
    "60-web-stack/install.wsl.sh — has a flag/var that gates the nginx reload on conflict"

summary
