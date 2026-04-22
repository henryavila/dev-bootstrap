#!/usr/bin/env bash
# tests/integration/templates.test.sh — every *.template renders cleanly
# with envsubst under the ENVSUBST_ALLOWLIST defined in lib/deploy.sh.
#
# What "cleanly" means:
#   - zero `${VAR}` literals remain in the output (all vars were resolved)
#   - every var referenced in the template is in the allowlist (otherwise
#     envsubst would silently skip it → bug)
#
# Guards against the NGINX_SNIPPET_DIR-class bug (template references a
# var the bootstrap doesn't export).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

# Extract allowlist from lib/deploy.sh (single source of truth)
allowlist_raw="$(grep '^ENVSUBST_ALLOWLIST=' "$REPO_ROOT/lib/deploy.sh" | head -1 | sed "s/.*='\(.*\)'/\1/")"

if [[ -z "$allowlist_raw" ]]; then
    fail "could not parse ENVSUBST_ALLOWLIST from lib/deploy.sh"
    summary
    exit 1
fi

pass "extracted ENVSUBST_ALLOWLIST: $allowlist_raw"

# Set every allowlist var to a non-empty mock value so envsubst expands them.
# Values are deliberately OS-generic; we're testing rendering, not semantics.
export USER="testuser"
export HOME="/tmp/home-test"
export BREW_PREFIX="/mock/brew"
export CODE_DIR="/mock/code"
export DOTFILES_DIR="/mock/dotfiles"
export NGINX_CONF_DIR="/mock/nginx/sites-enabled"
export NGINX_AVAILABLE_DIR="/mock/nginx/sites-available"
export NGINX_ENABLED_DIR="/mock/nginx/sites-enabled"
export NGINX_SNIPPET_DIR="/mock/nginx/snippets"
export NGINX_MAP_DIR="/mock/nginx/conf.d"
export CERT_DIR="/mock/nginx/certs"
export PHP_DEFAULT="8.5"
export DEV_DEFAULT_PORT="3000"

if ! command -v envsubst >/dev/null 2>&1; then
    fail "envsubst not installed — cannot render templates"
    summary
    exit 1
fi

echo "Rendering every *.template under topics/ with ENVSUBST_ALLOWLIST"

while IFS= read -r -d '' tmpl; do
    rel="${tmpl#"$REPO_ROOT"/}"
    rendered="$(envsubst "$allowlist_raw" < "$tmpl")"

    # 1. Output should not contain any `${...}` literal referencing an
    #    allowlisted var — that would mean the var was empty at substitution
    #    (and in real deploy, its surrounding path would collapse to "/").
    if grep -qE '\$\{[A-Z][A-Z_]*\}' <<< "$rendered"; then
        # Find the first offender and report — makes debugging MUCH easier
        first_bad="$(grep -oE '\$\{[A-Z][A-Z_]*\}' <<< "$rendered" | head -1)"
        fail "$rel still contains unresolved $first_bad after envsubst"
    else
        pass "$rel — all allowlist vars resolved"
    fi

    # 2. Every `${VAR}` in the template must be in the allowlist. Envsubst
    #    silently leaves non-listed vars alone; that creates subtle bugs.
    while IFS= read -r ref; do
        var="${ref#\$\{}"; var="${var%\}}"
        if [[ "$allowlist_raw" != *"\${$var}"* ]]; then
            fail "$rel references \${$var} but it's NOT in ENVSUBST_ALLOWLIST"
        fi
    done < <(grep -oE '\$\{[A-Z][A-Z_]*\}' "$tmpl" | sort -u)
done < <(find "$REPO_ROOT/topics" -type f -name '*.template' -print0)

summary
