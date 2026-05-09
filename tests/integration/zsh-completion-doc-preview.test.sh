#!/usr/bin/env bash
# tests/integration/zsh-completion-doc-preview.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

if ! command -v zsh >/dev/null 2>&1; then
    echo "zsh not installed; skipping zsh completion preview checks"
    summary
    exit 0
fi

TESTROOT="$(mktemp -d /tmp/dev-bootstrap-zsh-preview.XXXXXX)"
trap 'rm -rf "$TESTROOT"' EXIT INT TERM

cat > "$TESTROOT/doctool" <<'TOOL'
#!/usr/bin/env bash
if [ "$1" = "serve" ] && [ "$2" = "--help" ]; then
    printf '%s\n' 'DOC doctool serve --help'
    exit 0
fi
if [ "$1" = "--help" ]; then
    printf '%s\n' 'DOC doctool --help'
    exit 0
fi
exit 1
TOOL
chmod +x "$TESTROOT/doctool"

preview_out="$(
    PATH="$TESTROOT:$PATH" FZF_TAB_HELP_TIMEOUT=2 zsh -fic "
        source '$REPO_ROOT/topics/20-terminal-ux/templates/zshrc.d-20-terminal-ux.sh.template'
        zstyle -s ':fzf-tab:complete:*:*' fzf-preview preview
        words=(doctool '')
        word=serve
        desc='serve:Serve requests'
        eval \"\$preview\"
    " 2>/dev/null
)"

assert_contains "$preview_out" "serve:Serve requests" \
    "fzf-tab preview includes completer description"
assert_contains "$preview_out" "DOC doctool serve --help" \
    "fzf-tab preview executes subcommand --help"

mkdir -p "$TESTROOT/project" "$TESTROOT/bin"
touch "$TESTROOT/project/artisan"
chmod +x "$TESTROOT/project/artisan"
cat > "$TESTROOT/bin/php" <<'PHP'
#!/usr/bin/env bash
if [ "$1" = "./artisan" ] && [ "$2" = "list" ] && [ "$3" = "--raw" ]; then
    printf '%s\n' \
        'cache:clear Flush the application cache' \
        'route:list List all registered routes'
    exit 0
fi
exit 1
PHP
chmod +x "$TESTROOT/bin/php"

artisan_out="$(
    PATH="$TESTROOT/bin:$PATH" zsh -fic "
        cd '$TESTROOT/project' || exit 1
        autoload -Uz compinit
        compinit -i
        _php() { print -r -- PHP_FALLBACK_CALLED }
        _describe() {
            local array_name=\"\${@[-1]}\"
            print -rl -- \"\${(@P)array_name}\"
        }
        source '$REPO_ROOT/topics/60-web-stack/templates/zshrc.d-60-web-stack.sh'
        words=(art '')
        CURRENT=2
        _dev_bootstrap_artisan_completion
    " 2>/dev/null
)"

assert_contains "$artisan_out" 'cache\:clear:Flush the application cache' \
    "artisan completion preserves namespaces and descriptions"
assert_contains "$artisan_out" 'route\:list:List all registered routes' \
    "artisan completion includes route list description"

git_alias_out="$(
    zsh -fic "
        autoload -Uz compinit
        compinit -i
        source '$REPO_ROOT/topics/50-git/templates/zshrc.d-50-git.sh'
        print -r -- \"g=\${_comps[g]-MISSING} gs=\${_comps[gs]-MISSING} gco=\${_comps[gco]-MISSING}\"
    " 2>/dev/null
)"

assert_contains "$git_alias_out" "g=_git" \
    "git alias g maps to _git"
assert_contains "$git_alias_out" "gs=_git" \
    "git alias gs maps to _git"
assert_contains "$git_alias_out" "gco=_git" \
    "git alias gco maps to _git"

fpath_out="$(
    HOME="$TESTROOT/home" zsh -fic "
        mkdir -p \"\$HOME/.local/share/zsh/site-functions\"
        source '$REPO_ROOT/topics/30-shell/templates/zshrc.template'
        print -r -- \${fpath[(I)\$HOME/.local/share/zsh/site-functions]}
    " 2>/dev/null
)"

if [[ "$fpath_out" =~ ^[1-9][0-9]*$ ]]; then
    pass "30-shell adds user site-functions to fpath before compinit"
else
    fail "30-shell did not add user site-functions to fpath"
fi

deploy_home="$TESTROOT/deploy-home"
mkdir -p "$deploy_home"
HOME="$deploy_home" BREW_PREFIX="" \
    bash "$REPO_ROOT/lib/deploy.sh" "$REPO_ROOT/topics/20-terminal-ux/templates" >/dev/null

assert_file_contains "$deploy_home/.local/share/zsh/site-functions/_mesh" "run:run a mesh subcommand" \
    "20-terminal-ux deploys mesh completion into zsh site-functions"
assert_file_contains "$deploy_home/.local/share/zsh/site-functions/_mesh" "managed by dev-bootstrap" \
    "mesh completion is marked as dev-bootstrap-managed for future deploys"

mesh_completion_out="$(
    HOME="$deploy_home" zsh -fic "
        source '$REPO_ROOT/topics/30-shell/templates/zshrc.template'
        words=(mesh '')
        CURRENT=2
        curcontext=''
        _arguments() {
            state=subcommand
            return 0
        }
        _describe() {
            local array_name=\"\${@[-1]}\"
            print -rl -- \"\${(@P)array_name}\"
        }
        _files() { print -r -- FILE_FALLBACK; }
        autoload -Uz _mesh
        _mesh
    " 2>/dev/null
)"

assert_contains "$mesh_completion_out" "status:show cross-mesh status" \
    "mesh completion offers subcommands after 20-terminal-ux deploy"
assert_contains "$mesh_completion_out" "topic:list or run dev-bootstrap topics by number" \
    "mesh completion offers topic subcommand after 20-terminal-ux deploy"
assert_not_contains "$mesh_completion_out" "FILE_FALLBACK" \
    "mesh completion does not fall back to file listing"

mkdir -p "$TESTROOT/mesh-bin"
cat > "$TESTROOT/mesh-bin/mesh" <<'MESH'
#!/usr/bin/env bash
if [ "$1" = "topic" ] && [ "$2" = "list" ]; then
    printf '%s\n' \
        '20  20-terminal-ux' \
        '25  25-dynamic-test  opt-in: INCLUDE_DYNAMIC=1'
    exit 0
fi
exit 1
MESH
chmod +x "$TESTROOT/mesh-bin/mesh"

mesh_topic_completion_out="$(
    PATH="$TESTROOT/mesh-bin:/usr/bin:/bin" HOME="$deploy_home" zsh -fic "
        source '$REPO_ROOT/topics/30-shell/templates/zshrc.template'
        words=(mesh topic '')
        CURRENT=3
        curcontext=''
        _arguments() {
            state=topic_arg
            return 0
        }
        _describe() {
            local array_name=\"\${@[-1]}\"
            print -rl -- \"\${(@P)array_name}\"
        }
        _files() { print -r -- FILE_FALLBACK; }
        autoload -Uz _mesh
        _mesh
    " 2>/dev/null
)"

assert_contains "$mesh_topic_completion_out" "list:list dev-bootstrap topics" \
    "mesh topic completion offers list command"
assert_contains "$mesh_topic_completion_out" "20:20-terminal-ux" \
    "mesh topic completion offers numeric topic selectors"
assert_contains "$mesh_topic_completion_out" "25:25-dynamic-test" \
    "mesh topic completion reads topic selectors from mesh topic list"
assert_not_contains "$mesh_topic_completion_out" "FILE_FALLBACK" \
    "mesh topic completion does not fall back to file listing"

mkdir -p "$TESTROOT/completion-bin" "$TESTROOT/site-functions"
cat > "$TESTROOT/completion-bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1" = "completion" ] && [ "$2" = "-s" ] && [ "$3" = "zsh" ]; then
    printf '%s\n' '#compdef gh' '_gh() { _files }'
    exit 0
fi
exit 1
GH
cat > "$TESTROOT/completion-bin/uv" <<'UV'
#!/usr/bin/env bash
if [ "$1" = "generate-shell-completion" ] && [ "$2" = "zsh" ]; then
    printf '%s\n' '#compdef uv' '_uv() { _files }'
    exit 0
fi
exit 1
UV
cat > "$TESTROOT/completion-bin/atuin" <<'ATUIN'
#!/usr/bin/env bash
if [ "$1" = "gen-completions" ] && [ "$2" = "--shell" ] && [ "$3" = "zsh" ]; then
    printf '%s\n' '#compdef atuin' '_atuin() { _files }'
    exit 0
fi
exit 1
ATUIN
cat > "$TESTROOT/completion-bin/pip" <<'PIP'
#!/usr/bin/env bash
if [ "$1" = "completion" ] && [ "$2" = "--zsh" ]; then
    printf '%s\n' '#compdef pip' '_pip() { _files }'
    exit 0
fi
exit 1
PIP
chmod +x "$TESTROOT/completion-bin/"*

PATH="$TESTROOT/completion-bin:$PATH" \
ZSH_COMPLETION_TARGET_DIR="$TESTROOT/site-functions" \
    bash "$REPO_ROOT/topics/20-terminal-ux/scripts/generate-zsh-completions.sh" >/dev/null

assert_file_contains "$TESTROOT/site-functions/_gh" "#compdef gh" \
    "completion generator writes gh completion"
assert_file_contains "$TESTROOT/site-functions/_uv" "#compdef uv" \
    "completion generator writes uv completion"
assert_file_contains "$TESTROOT/site-functions/_atuin" "#compdef atuin" \
    "completion generator writes atuin completion"
assert_file_contains "$TESTROOT/site-functions/_pip" "#compdef pip" \
    "completion generator writes pip completion"

summary
