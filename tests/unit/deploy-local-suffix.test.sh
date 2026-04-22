#!/usr/bin/env bash
# tests/unit/deploy-local-suffix.test.sh — regression test for
# `refuse_local_suffix` in lib/deploy.sh.
#
# THE BUG it guards against: the pattern `*/.local/*` refuses ANY path
# containing a `.local/` directory component — which catches XDG-standard
# `~/.local/bin/...` (where 60-laravel-stack and 10-languages legitimately
# deploy CLI helpers) and breaks deploy.
#
# The real invariant the function intends to protect: **filenames** with
# a `.local` suffix (e.g. `.bashrc.local`, `.zshrc.local`), which are by
# convention user-owned overrides loaded after bootstrap-managed files.
#
# Test strategy: extract `refuse_local_suffix` from lib/deploy.sh (avoids
# the setup boilerplate that requires argv + log.sh) and exercise it
# head-on with a table of (path, should_refuse?) pairs.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

DEPLOY_SH="$REPO_ROOT/lib/deploy.sh"
assert_file_exists "$DEPLOY_SH"

# Build a minimal harness that loads just the function under test.
# We can't `source deploy.sh` directly because it has top-level `set -e`
# side effects. Instead, extract the function body into a tmp file and
# source that.
harness="$(mktemp)"
trap 'rm -f "$harness"' EXIT

# The harness stubs `fail` → swallow stderr. We use a unique name
# (__deploy_fail) inside the sourced function to avoid overwriting the
# real `fail()` in assert.sh (which increments the FAIL counter).
cat > "$harness" <<'HARNESS_EOF'
__deploy_fail() { :; }  # silent stub
HARNESS_EOF
# Extract the function + rewrite `fail` → `__deploy_fail` so the function
# doesn't call the assert.sh fail and confuse the counter.
sed -n '/^refuse_local_suffix()/,/^}/p' "$DEPLOY_SH" \
    | sed 's/^    fail /    __deploy_fail /' \
    >> "$harness"

# shellcheck source=/dev/null
source "$harness"

# Helper: run refuse_local_suffix in a subshell and report whether it
# refused (exit 1) or allowed (no exit, subshell completes normally).
# Returns 0 == ALLOWED; 1 == REFUSED.
call_refuse() {
    local path="$1"
    ( refuse_local_suffix "test" "$path" ) >/dev/null 2>&1
}

echo "paths that MUST be ALLOWED (XDG dir, unrelated paths with .local coincidence)"

_allow_cases=(
    "${HOME}/.local/bin/link-project"     # the bug — ~/.local/bin is XDG, not a suffix
    "${HOME}/.local/bin/php-use"
    "${HOME}/.local/bin/share-project"
    "${HOME}/.local/share/fnm/fnm"
    "${HOME}/.local/share/zsh/foo"
    "/opt/.local/something"               # hypothetical dir-of-.local in /opt
    "/var/lib/mysql-files/foo"            # plain path, no .local at all
    "${HOME}/.bashrc.d/50-git.sh"
    "${HOME}/.config/bat/themes/X.tmTheme"
    "/etc/nginx/sites-available/catchall.conf"
)

for p in "${_allow_cases[@]}"; do
    ASSERT_MSG="allow: $p"
    if call_refuse "$p"; then
        # Subshell ran without exit → allowed → pass
        pass "$ASSERT_MSG"
    else
        fail "$ASSERT_MSG (refused — but this is a legitimate XDG/regular path)"
    fi
done

echo
echo "paths that MUST be REFUSED (.local suffix on FILENAME, user-override invariant)"

_refuse_cases=(
    "${HOME}/.bashrc.local"               # classic user override
    "${HOME}/.zshrc.local"                # ditto
    "${HOME}/shell/aliases.local"         # any file ending .local
    "/tmp/config.local"                   # outside HOME, same rule
    "${HOME}/config.local.example"        # .local.<ext>
    "${HOME}/config.local.backup"
)

for p in "${_refuse_cases[@]}"; do
    ASSERT_MSG="refuse: $p"
    if call_refuse "$p"; then
        fail "$ASSERT_MSG (allowed — should have refused as user-override file)"
    else
        pass "$ASSERT_MSG"
    fi
done

summary
