#!/usr/bin/env bash
# tests/integration/mesh-command-cleanup.test.sh
#
# T3.3 contract: remaining built-ins are modules, the legacy public command
# registration list is gone, and public command surfaces derive from the
# registry instead of parallel hand-maintained lists.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
MESH="$REPO_ROOT/bin/mesh"

# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-command-cleanup.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

IDENTITY_EMPTY="$SANDBOX/identity-empty"
mkdir -p "$IDENTITY_EMPTY"

public_commands() {
    MESH_IDENTITY_DIR="$IDENTITY_EMPTY" "$MESH" __commands \
        | awk -F '\t' 'NF >= 1 { print $1 }'
}

help_command_names() {
    awk '
        /^Commands:$/ { in_commands = 1; next }
        in_commands && /^$/ { exit }
        in_commands && /^  [a-z][a-z0-9-]+[[:space:]]/ { print $1 }
    '
}

echo "final command modules"
for name in doctor adopt setup ai help; do
    module="$REPO_ROOT/scripts/commands/$name.sh"
    assert_file_exists "$module" "module exists for $name"
    assert_file_contains "$module" "mesh_register_command" "module registers $name"
    assert_pattern_present "$module" "[[:space:]]--name $name" "module owns $name metadata"
    assert_pattern_absent "$REPO_ROOT/bin/mesh" "^sub_${name}\\(\\)" "bin/mesh no longer defines sub_${name}"
done

echo
echo "legacy public command list removed"
assert_pattern_absent "$REPO_ROOT/bin/mesh" '_mesh_register_legacy_command' \
    "bin/mesh has no legacy public command registration helper"
assert_pattern_absent "$REPO_ROOT/bin/mesh" '_mesh_register_legacy_commands' \
    "bin/mesh has no legacy public command registration list"

echo
echo "source-pure registration"
source_check="$(
    REPO_ROOT="$REPO_ROOT" bash <<'SH'
set -uo pipefail
source "$REPO_ROOT/scripts/lib/mesh-command.sh"
_die() { printf 'DIE:%s\n' "$*" >&2; exit 1; }
_resolve_companion() { printf '/nonexistent/%s\n' "$1"; }
_resolve_workstation_repo() { printf '/nonexistent/workstation\n'; }
HERE="$REPO_ROOT/bin"
for module in run doctor adopt setup ai help; do
    source "$REPO_ROOT/scripts/commands/$module.sh"
done
mesh_command_emit_tsv --internal
SH
)"
for name in doctor adopt setup ai help run; do
    count="$(printf '%s\n' "$source_check" | awk -F '\t' -v n="$name" '$1 == n { c++ } END { print c + 0 }')"
    assert_eq "$count" "1" "source registers $name exactly once"
done

echo
echo "registry/help/catalog surfaces"
expected_names="$(public_commands)"
duplicates="$(printf '%s\n' "$expected_names" | awk '{ c[$1]++ } END { for (n in c) if (c[n] > 1) print n }' | LC_ALL=C sort)"
assert_eq "$duplicates" "" "mesh __commands has no duplicate public command names"

help_out="$(MESH_IDENTITY_DIR="$IDENTITY_EMPTY" "$MESH" --help 2>&1)"
actual_help_names="$(printf '%s\n' "$help_out" | help_command_names)"
assert_eq "$actual_help_names" "$expected_names" "help command table matches public __commands names"

if [[ -f "$REPO_ROOT/.catalog/cli.txt" ]]; then
    catalog_names="$(cat "$REPO_ROOT/.catalog/cli.txt")"
    expected_catalog="$(printf '%s\n' "$expected_names" | LC_ALL=C sort -u)"
    assert_eq "$catalog_names" "$expected_catalog" ".catalog/cli.txt matches public __commands names"
else
    fail ".catalog/cli.txt exists"
fi

echo
echo "completion source"
if [[ -f "$REPO_ROOT/topics/shell-terminal/templates/zsh/zsh-site-functions/_mesh" ]]; then
    pass "public registry-backed _mesh completion source exists"
else
    fail "public registry-backed _mesh completion source exists"
fi

if [[ -e "$REPO_ROOT/template/shell/completions/_mesh.example" ]]; then
    fail "identity template does not ship a private _mesh completion"
else
    pass "identity template does not ship a private _mesh completion"
fi

if command -v zsh >/dev/null 2>&1; then
    mkdir -p "$SANDBOX/fake-bin"
    commands_tsv="$SANDBOX/commands.tsv"
    MESH_IDENTITY_DIR="$IDENTITY_EMPTY" "$MESH" __commands > "$commands_tsv"
    cat > "$SANDBOX/fake-bin/mesh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "__commands" ]; then
    cat "$MESH_COMMANDS_TSV"
    exit 0
fi
exit 1
SH
    chmod +x "$SANDBOX/fake-bin/mesh"
    completion_out="$(
        PATH="$SANDBOX/fake-bin:/usr/bin:/bin" MESH_COMMANDS_TSV="$commands_tsv" zsh -fic "
            source '$REPO_ROOT/topics/shell-terminal/templates/zsh/zsh-site-functions/_mesh'
            words=(mesh '')
            CURRENT=2
            curcontext=''
            _arguments() { state=subcommand; return 0; }
            _describe() {
                local array_name=\"\${@[-1]}\"
                print -rl -- \"\${(@P)array_name}\"
            }
            _files() { print -r -- FILE_FALLBACK; }
            _mesh
        " 2>/dev/null
    )"
    completion_names="$(printf '%s\n' "$completion_out" | sed 's/:.*//' | sed '/^$/d')"
    assert_eq "$completion_names" "$expected_names" "zsh completion command list matches public __commands names"
    assert_not_contains "$completion_out" "FILE_FALLBACK" "zsh completion does not fall back to file listing"
else
    pass "zsh completion runtime check skipped (zsh unavailable)"
fi

echo
summary
