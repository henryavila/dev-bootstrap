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

summary
