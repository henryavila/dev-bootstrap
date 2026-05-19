#!/usr/bin/env bash
# tests/integration/mesh-extension-hook.test.sh — exercises the C3 extension hook.
#
# Contract:
#   - bin/mesh sources $MESH_IDENTITY_DIR/extensions/mesh.sh if present
#   - extension may define `sub_<name>` functions
#   - dispatcher's `*)` fallback routes unknown subcommand to extension sub
#   - hyphenated subcommand `mesh foo-bar` maps to function `sub_foo_bar`
#   - extension absent ⇒ no error, dispatcher works normally
#   - extension unreadable ⇒ no error (silently skipped)
#   - exit code from extension sub propagates to caller

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
MESH="$REPO_ROOT/bin/mesh"

# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-extension-hook.XXXXXX)"
_cleanup() { [[ -d "$SANDBOX" ]] && rm -rf "$SANDBOX"; }
trap _cleanup EXIT

# ─── Test 1: extension-defined sub is invoked ──────────────────────
IDENTITY1="$SANDBOX/identity1"
mkdir -p "$IDENTITY1/extensions"
cat > "$IDENTITY1/extensions/mesh.sh" <<'EOF'
sub_hello() {
    printf 'hello from extension args=%s\n' "$*"
    return 0
}
EOF

out=$(MESH_IDENTITY_DIR="$IDENTITY1" MESH_HOME="$REPO_ROOT/scripts" "$MESH" hello world 2>&1)
rc=$?
assert_eq "$rc" 0 "Test 1a: extension sub_hello exits 0"
assert_contains "$out" "hello from extension" "Test 1b: extension output reaches caller"
assert_contains "$out" "args=world" "Test 1c: extension receives args"

# ─── Test 2: hyphenated subcommand maps to underscore function ─────
IDENTITY2="$SANDBOX/identity2"
mkdir -p "$IDENTITY2/extensions"
cat > "$IDENTITY2/extensions/mesh.sh" <<'EOF'
sub_code_server() {
    case "${1:-status}" in
        status) echo "code-server: running"; return 0 ;;
        bogus)  return 17 ;;
        *)      echo "code-server: unknown"; return 2 ;;
    esac
}
EOF

out=$(MESH_IDENTITY_DIR="$IDENTITY2" MESH_HOME="$REPO_ROOT/scripts" "$MESH" code-server status 2>&1)
rc=$?
assert_eq "$rc" 0 "Test 2a: hyphenated `code-server` routes to sub_code_server"
assert_contains "$out" "code-server: running" "Test 2b: extension sub output reaches caller"

# Exit code propagation
MESH_IDENTITY_DIR="$IDENTITY2" MESH_HOME="$REPO_ROOT/scripts" "$MESH" code-server bogus 2>/dev/null
assert_eq "$?" 17 "Test 2c: extension sub exit code propagates"

# ─── Test 3: missing extension is non-fatal ────────────────────────
IDENTITY3="$SANDBOX/identity3-no-ext"
mkdir -p "$IDENTITY3"  # no extensions/ dir

out=$(MESH_IDENTITY_DIR="$IDENTITY3" MESH_HOME="$REPO_ROOT/scripts" "$MESH" --version 2>&1)
rc=$?
assert_eq "$rc" 0 "Test 3a: --version works without extension"
assert_contains "$out" "mesh CLI" "Test 3b: --version output unaffected"

# Unknown sub without extension still fails normally
MESH_IDENTITY_DIR="$IDENTITY3" MESH_HOME="$REPO_ROOT/scripts" "$MESH" nonsense 2>/dev/null
assert_eq "$?" 1 "Test 3c: unknown sub still rc=1 without extension"

# ─── Test 4: unreadable extension is non-fatal ─────────────────────
IDENTITY4="$SANDBOX/identity4"
mkdir -p "$IDENTITY4/extensions"
: > "$IDENTITY4/extensions/mesh.sh"
chmod 000 "$IDENTITY4/extensions/mesh.sh"

out=$(MESH_IDENTITY_DIR="$IDENTITY4" MESH_HOME="$REPO_ROOT/scripts" "$MESH" --version 2>&1)
rc=$?
chmod 644 "$IDENTITY4/extensions/mesh.sh"  # restore for cleanup
assert_eq "$rc" 0 "Test 4: unreadable extension does not break dispatcher"

# ─── Test 5: extension cannot override built-in subs ───────────────
# (built-in `case` branches match first; extension fallback is only `*)`)
IDENTITY5="$SANDBOX/identity5"
mkdir -p "$IDENTITY5/extensions"
cat > "$IDENTITY5/extensions/mesh.sh" <<'EOF'
sub_lint() {
    echo "MALICIOUS OVERRIDE"
    return 99
}
EOF

out=$(MESH_IDENTITY_DIR="$IDENTITY5" MESH_HOME="$REPO_ROOT/scripts" "$MESH" lint 2>&1) || true
rc=$?
assert_not_contains "$out" "MALICIOUS OVERRIDE" "Test 5a: built-in lint shadows extension sub_lint"
assert_ne "$rc" 99 "Test 5b: extension cannot hijack rc of built-in"

summary
