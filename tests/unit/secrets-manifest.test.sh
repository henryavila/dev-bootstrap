#!/usr/bin/env bash
# Unit tests for scripts/lib/secrets-manifest.sh (secrets layer manifest reader).
# Bash 3.2 compatible.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
PARSER="$WS/scripts/lib/secrets-manifest.sh"

pass=0; fail=0; fails=""
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); fails="$fails
  FAIL: $1"; }

# parse <manifest-text> → sets global `parsed`; returns parser rc.
parse() {
    parsed="$(printf '%s\n' "$1" | bash "$PARSER")"
    return $?
}

# --- valid manifest round-trips through eval with sentinel ---
MANIFEST='version: 1
integrations:
  composer-auth:
    tier: 2
    type: file
    source: secrets/composer/auth.json
    dest_resolver: composer-home
    dest_file: auth.json
    perms: "0600"
    machines: [mac, ultron]
    description: "Composer http-basic creds"
  anthropic:
    tier: 2
    type: env-token
    key: ANTHROPIC_API_KEY
    description: API key from console
  github:
    tier: 1
    type: login
    check: gh auth status
    login: gh auth login'

if parse "$MANIFEST"; then ok; else no "valid manifest should parse (rc 0)"; fi
eval "$parsed"
[ "${__SECRETS_MANIFEST_OK:-0}" = "1" ] && ok || no "sentinel missing"
[ "${MANIFEST_VERSION:-}" = "1" ] && ok || no "version should be 1 (got '${MANIFEST_VERSION:-}')"
[ "${INTEGRATION_COUNT:-}" = "3" ] && ok || no "should have 3 integrations (got '${INTEGRATION_COUNT:-}')"

# --- field extraction ---
[ "${INTEGRATION_0_ID:-}" = "composer-auth" ] && ok || no "int0 id"
[ "${INTEGRATION_0_TIER:-}" = "2" ] && ok || no "int0 tier"
[ "${INTEGRATION_0_TYPE:-}" = "file" ] && ok || no "int0 type"
[ "${INTEGRATION_0_SOURCE:-}" = "secrets/composer/auth.json" ] && ok || no "int0 source"
[ "${INTEGRATION_0_DEST_RESOLVER:-}" = "composer-home" ] && ok || no "int0 dest_resolver"
[ "${INTEGRATION_0_DEST_FILE:-}" = "auth.json" ] && ok || no "int0 dest_file"
[ "${INTEGRATION_0_PERMS:-}" = "0600" ] && ok || no "int0 perms (quotes stripped)"
[ "${INTEGRATION_0_DESCRIPTION:-}" = "Composer http-basic creds" ] && ok || no "int0 description"

# --- inline list (machines) ---
[ "${INTEGRATION_0_MACHINES_COUNT:-}" = "2" ] && ok || no "machines count 2"
[ "${INTEGRATION_0_MACHINES_0:-}" = "mac" ] && ok || no "machines[0]=mac"
[ "${INTEGRATION_0_MACHINES_1:-}" = "ultron" ] && ok || no "machines[1]=ultron"

# --- second + third integrations ---
[ "${INTEGRATION_1_ID:-}" = "anthropic" ] && ok || no "int1 id"
[ "${INTEGRATION_1_KEY:-}" = "ANTHROPIC_API_KEY" ] && ok || no "int1 key"
[ "${INTEGRATION_2_ID:-}" = "github" ] && ok || no "int2 id"
[ "${INTEGRATION_2_TIER:-}" = "1" ] && ok || no "int2 tier 1"
[ "${INTEGRATION_2_CHECK:-}" = "gh auth status" ] && ok || no "int2 check (value with spaces)"
[ "${INTEGRATION_2_LOGIN:-}" = "gh auth login" ] && ok || no "int2 login"

# --- empty manifest (only version) ---
if parse 'version: 1
integrations:'; then ok; else no "empty integrations should parse"; fi
eval "$parsed"
[ "${INTEGRATION_COUNT:-x}" = "0" ] && ok || no "empty → 0 integrations (got '${INTEGRATION_COUNT:-x}')"

# --- comments + blank lines ignored ---
if parse '# top comment
version: 1

integrations:
  # a comment
  foo:
    tier: 2

    type: env-token'; then ok; else no "comments/blanks should parse"; fi
eval "$parsed"
[ "${INTEGRATION_COUNT:-}" = "1" ] && ok || no "comments → 1 integration"
[ "${INTEGRATION_0_ID:-}" = "foo" ] && ok || no "comment manifest id=foo"

# --- rejection: tab indentation ---
printf 'version: 1\nintegrations:\n\tfoo:\n' | bash "$PARSER" >/dev/null 2>&1
[ $? -ne 0 ] && ok || no "tabs should be rejected"

# --- rejection: bad indent (3 spaces / depth 6) ---
printf 'version: 1\nintegrations:\n  foo:\n      bar: baz\n' | bash "$PARSER" >/dev/null 2>&1
[ $? -ne 0 ] && ok || no "indent 6 should be rejected (flat grammar)"

# --- rejection: invalid integration id ---
printf 'version: 1\nintegrations:\n  bad id:\n' | bash "$PARSER" >/dev/null 2>&1
[ $? -ne 0 ] && ok || no "invalid id (space) should be rejected"

# --- single-quoted value strips quotes ---
if parse "version: 1
integrations:
  q:
    description: 'single quoted'"; then ok; else no "single-quote manifest parse"; fi
eval "$parsed"
[ "${INTEGRATION_0_DESCRIPTION:-}" = "single quoted" ] && ok || no "single quotes stripped"

# --- summary ---
total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    printf 'secrets-manifest.test.sh: %d/%d PASS\n' "$pass" "$total"
    exit 0
else
    printf 'secrets-manifest.test.sh: %d/%d PASS, %d FAIL%b\n' "$pass" "$total" "$fail" "$fails"
    exit 1
fi
