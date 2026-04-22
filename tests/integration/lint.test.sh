#!/usr/bin/env bash
# tests/integration/lint.test.sh — syntax-check every shell + JSON in the repo.
#
# Mirrors what CI Tier 1 does (and catches issues before the push).
# No sandboxing needed — lint is pure read-only parsing.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

echo "bash -n on every *.sh + *.template in topics/ and lib/"

# bash -n on all shell files. Excludes *.conf.template (nginx snippets,
# systemd units, etc. — those aren't shell and bash -n would false-fail).
# Convention used: shell-template has either a shebang or lives under bin/.
is_shell_template() {
    local f="$1"
    # Non-template shell files (.sh) are always in-scope.
    [[ "$f" == *.sh ]] && return 0
    # .conf.template files are nginx/systemd/etc — definitely not shell.
    [[ "$f" == *.conf.template ]] && return 1
    # .template under bin/ is always a script wrapper.
    [[ "$f" == */bin/*.template ]] && return 0
    # bashrc / zshrc / inputrc templates are shell.
    case "$(basename "$f")" in
        bashrc.template|zshrc.template|bashrc.d-*.template|zshrc.d-*.template|\
        inputrc.template|starship.toml*)
            return 0 ;;
    esac
    # bashrc.d-*.sh.template / zshrc.d-*.sh.template
    [[ "$f" == *.sh.template ]] && return 0
    return 1
}

while IFS= read -r -d '' f; do
    is_shell_template "$f" || continue
    ASSERT_MSG="$(realpath --relative-to="$REPO_ROOT" "$f")"
    assert_true "bash -n '$f'"
done < <(find "$REPO_ROOT/topics" "$REPO_ROOT/lib" "$REPO_ROOT/ci" \
             -type f \( -name '*.sh' -o -name '*.template' \) -print0 2>/dev/null)

# bootstrap.sh + tests themselves
for f in "$REPO_ROOT/bootstrap.sh" \
         "$HERE/../run-all.sh" \
         "$HERE/../lib/assert.sh"; do
    ASSERT_MSG="$(realpath --relative-to="$REPO_ROOT" "$f")"
    assert_true "bash -n '$f'"
done

echo
echo "JSON syntax (jq parse)"

if command -v jq >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do
        ASSERT_MSG="$(realpath --relative-to="$REPO_ROOT" "$f")"
        assert_true "jq empty < '$f'"
    done < <(find "$REPO_ROOT/topics" -type f -name '*.json' -print0 2>/dev/null)
else
    echo "  (skipped — jq not installed)"
fi

echo
echo "data/*.conf + *.txt files non-empty (SoT files)"
for data_file in "$REPO_ROOT/topics/10-languages/data/"*.{conf,txt}; do
    [[ ! -f "$data_file" ]] && continue
    ASSERT_MSG="$(realpath --relative-to="$REPO_ROOT" "$data_file")"
    assert_true "grep -qvE '^\s*(#|$)' '$data_file'"
done

echo
echo "bash 3.2 compat — no bash-4-only builtins in scripts that run on Mac"
# macOS default bash is 3.2 (frozen for GPL-3 reasons). Any script that
# runs on Mac (install.mac.sh, install.sh, anything called from them)
# must avoid bash-4+ builtins. Flagged builtins:
#   - mapfile / readarray → use `while IFS= read -r` loop
#   - associative arrays (declare -A) → use indexed arrays or two parallel arrays
#
# We explicitly check Mac-reachable scripts. install.wsl.sh is Linux-only
# and could use bash 4 features, but we enforce portability there too
# (costs nothing, gives us a useful invariant).

bash4_patterns=(
    'mapfile'
    'readarray'
    'declare -A'
)
# Scripts that can run on Mac: install.mac.sh + install.sh (OS-agnostic)
# + any helper they source. Keep the scope conservative; widen if needed.
mac_reachable=(
    "$REPO_ROOT/topics"/*/install.mac.sh
    "$REPO_ROOT/topics"/*/install.sh
    "$REPO_ROOT/topics"/*/scripts/*.sh
    "$REPO_ROOT/lib"/*.sh
    "$REPO_ROOT/bootstrap.sh"
)
for script in "${mac_reachable[@]}"; do
    [[ ! -f "$script" ]] && continue
    for pattern in "${bash4_patterns[@]}"; do
        # Allow the pattern inside comments (documentation is fine).
        if grep -vE '^\s*#' "$script" | grep -qE "(^|[^a-zA-Z_])${pattern}([^a-zA-Z_]|$)"; then
            ASSERT_MSG="no '$pattern' in $(realpath --relative-to="$REPO_ROOT" "$script") (bash 3.2 compat)"
            fail "$ASSERT_MSG"
        fi
    done
done
# Emit a pass when nothing flagged
if [[ "$FAIL" -eq 0 ]]; then
    pass "no bash-4-only builtins in Mac-reachable scripts"
fi

summary
