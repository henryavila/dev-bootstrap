#!/usr/bin/env bash
# Unit test for run_setup_interactive (C2): proves the subshell wipes
# automation pre-seeds before invoking setup.sh, so a `mesh update --full
# --interactive` actually surfaces the menu instead of silently re-using
# the parent shell's INCLUDE_* / NON_INTERACTIVE exports.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
AU="$WS/scripts/runners/auto-update.sh"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected: '$expected', got: '$actual')" >&2; fi
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Extract just run_setup_interactive function from auto-update.sh so we
# don't have to source the whole script (which has heavy init at top-level).
func_src=$(awk '
    /^run_setup_interactive\(\)/ { capture=1 }
    capture { print }
    capture && /^}/ { exit }
' "$AU")
[[ -n "$func_src" ]] || { echo "FAIL: could not extract run_setup_interactive from $AU" >&2; exit 1; }
eval "$func_src"

# Fake repo with a setup.sh recorder that dumps the env vars we care about.
mkdir -p "$TMP/repo"
cat > "$TMP/repo/setup.sh" <<EOF
#!/usr/bin/env bash
# Dump each tracked var; "" means unset OR empty (both are "menu OK" from
# should_show_menu's perspective).
{
    printf 'NON_INTERACTIVE=%s\n' "\${NON_INTERACTIVE:-}"
    printf 'CI=%s\n' "\${CI:-}"
    printf 'ONLY_TOPICS=%s\n' "\${ONLY_TOPICS:-}"
    printf 'INCLUDE_DOCKER=%s\n' "\${INCLUDE_DOCKER:-}"
    printf 'INCLUDE_WEBSTACK=%s\n' "\${INCLUDE_WEBSTACK:-}"
    printf 'INCLUDE_LARAVEL=%s\n' "\${INCLUDE_LARAVEL:-}"
    printf 'INCLUDE_REMOTE=%s\n' "\${INCLUDE_REMOTE:-}"
    printf 'INCLUDE_EDITOR=%s\n' "\${INCLUDE_EDITOR:-}"
    printf 'INCLUDE_MAILPIT=%s\n' "\${INCLUDE_MAILPIT:-}"
    printf 'INCLUDE_NGROK=%s\n' "\${INCLUDE_NGROK:-}"
    printf 'INCLUDE_MSSQL=%s\n' "\${INCLUDE_MSSQL:-}"
    printf 'INCLUDE_FRONTEND_PROXY=%s\n' "\${INCLUDE_FRONTEND_PROXY:-}"
    printf 'INCLUDE_POSTGRES=%s\n' "\${INCLUDE_POSTGRES:-}"
    printf 'PHP_VERSIONS=%s\n' "\${PHP_VERSIONS:-}"
    printf 'PHP_DEFAULT=%s\n' "\${PHP_DEFAULT:-}"
    printf 'POSTGRES_VERSION=%s\n' "\${POSTGRES_VERSION:-}"
    printf 'DOTFILES_REPO=%s\n' "\${DOTFILES_REPO:-}"
    # CP4 D-F-003: newer menu-suppressor gates that were silently leaking through.
    printf 'INCLUDE_AI_TOOLS=%s\n' "\${INCLUDE_AI_TOOLS:-}"
    printf 'INCLUDE_CODE_SERVER=%s\n' "\${INCLUDE_CODE_SERVER:-}"
    printf 'INCLUDE_DOTFILES_PERSONAL=%s\n' "\${INCLUDE_DOTFILES_PERSONAL:-}"
    printf 'INCLUDE_NPM_GLOBAL=%s\n' "\${INCLUDE_NPM_GLOBAL:-}"
    printf 'DOTFILES_NPM_GLOBAL=%s\n' "\${DOTFILES_NPM_GLOBAL:-}"
    printf 'DOTFILES_AI_PACKAGES=%s\n' "\${DOTFILES_AI_PACKAGES:-}"
    printf 'DRY_RUN=%s\n' "\${DRY_RUN:-}"
    printf 'INNOCENT_VAR=%s\n' "\${INNOCENT_VAR:-}"
} > "$TMP/recorded.env"
EOF
chmod +x "$TMP/repo/setup.sh"

# Pre-seed all 14 automation vars + an unrelated INNOCENT_VAR to prove
# the unset is targeted, not scorched-earth.
export NON_INTERACTIVE=1 CI=1 ONLY_TOPICS=30-shell DRY_RUN=1
export INCLUDE_DOCKER=1 INCLUDE_WEBSTACK=1 INCLUDE_LARAVEL=1 INCLUDE_REMOTE=1 INCLUDE_EDITOR=1
export INCLUDE_MAILPIT=1 INCLUDE_NGROK=1 INCLUDE_MSSQL=1 INCLUDE_FRONTEND_PROXY=1
export INCLUDE_POSTGRES=1 PHP_VERSIONS=8.3 PHP_DEFAULT=8.3 POSTGRES_VERSION=16 DOTFILES_REPO=git@github.com:foo/bar
# CP4 D-F-003: newer gates that should ALSO be wiped.
export INCLUDE_AI_TOOLS=1 INCLUDE_CODE_SERVER=1 INCLUDE_DOTFILES_PERSONAL=1 INCLUDE_NPM_GLOBAL=1
export DOTFILES_NPM_GLOBAL=1 DOTFILES_AI_PACKAGES=1
export INNOCENT_VAR=keep-me

run_setup_interactive "$TMP/repo"

# Each tracked var must show empty in the recorded env (unset by the
# subshell before exec).
read_recorded() {
    grep -E "^$1=" "$TMP/recorded.env" | head -1 | cut -d= -f2-
}

for v in NON_INTERACTIVE CI ONLY_TOPICS DRY_RUN INCLUDE_DOCKER INCLUDE_WEBSTACK \
         INCLUDE_LARAVEL INCLUDE_REMOTE INCLUDE_EDITOR INCLUDE_MAILPIT \
         INCLUDE_NGROK INCLUDE_MSSQL INCLUDE_FRONTEND_PROXY INCLUDE_POSTGRES \
         PHP_VERSIONS PHP_DEFAULT POSTGRES_VERSION DOTFILES_REPO \
         INCLUDE_AI_TOOLS INCLUDE_CODE_SERVER INCLUDE_DOTFILES_PERSONAL \
         INCLUDE_NPM_GLOBAL DOTFILES_NPM_GLOBAL DOTFILES_AI_PACKAGES; do
    assert "$v unset in setup.sh subshell" "" "$(read_recorded "$v")"
done

# Sanity: unrelated var is preserved (subshell inherits everything except
# the explicit unsets).
assert "INNOCENT_VAR preserved in subshell" "keep-me" "$(read_recorded INNOCENT_VAR)"

# Parent shell still has the vars (subshell scoped the unsets).
assert "NON_INTERACTIVE preserved in parent"  "1"          "${NON_INTERACTIVE:-}"
assert "INCLUDE_DOCKER preserved in parent"   "1"          "${INCLUDE_DOCKER:-}"
assert "POSTGRES_VERSION preserved in parent" "16"         "${POSTGRES_VERSION:-}"

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
