#!/usr/bin/env bash
# Verifies each driver source-cleanly and exports expected functions.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
DRIVERS_DIR="$WS/scripts/lib/installers"

passed=0; failed=0
for driver in "$DRIVERS_DIR"/*.sh; do
    name=$(basename "$driver" .sh)
    prefix="${name//-/_}"
    # Source in a subshell, check that ${prefix}_check and ${prefix}_install exist.
    ok=$(bash -c ". '$driver' 2>/dev/null; declare -f ${prefix}_check >/dev/null && declare -f ${prefix}_install >/dev/null && echo yes || echo no")
    if [[ "$ok" == "yes" ]]; then passed=$((passed+1)); echo "  ✓ $name exports check + install"
    else failed=$((failed+1)); echo "  ✗ $name missing check or install" >&2; fi
done

# CP4 A2-F-009 regression: cargo_check + npm_global_check must treat the
# package name as a LITERAL, not as a regex pattern. Fake `cargo` and `npm`
# on PATH to control input + verify metachar safety.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# cargo_check with regex-metachar-containing name must not false-match.
# Scenario: list contains `foo v1.0.0:` but we ask for `f.o`. Regex grep would
# match (`.` = any char). awk literal-index must NOT match.
cat > "$TMP/bin/cargo" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "install" && "$2" == "--list" ]] && printf 'foo v1.0.0:\n    foo\n'
EOF
chmod +x "$TMP/bin/cargo"
(
    PATH="$TMP/bin:$PATH"
    . "$DRIVERS_DIR/cargo.sh"
    cargo_check "f.o" && exit 1   # regex would match, literal must not
    cargo_check "foo" || exit 2   # exact must match
    exit 0
) && { passed=$((passed+1)); echo "  ✓ A2-F-009 cargo_check uses literal substring (no regex metachar leak)"; } \
   || { failed=$((failed+1)); echo "  ✗ A2-F-009 cargo_check still regex-matches" >&2; }

# npm_global_check uses --parseable. Fake npm: only returns a path when the
# requested package matches exactly. A regex query like `f.o` should not yield
# a path (npm itself rejects unknown names).
cat > "$TMP/bin/npm" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--parseable foo"* ]]; then
    echo "/usr/lib/node_modules/foo"
fi
EOF
chmod +x "$TMP/bin/npm"
(
    PATH="$TMP/bin:$PATH"
    . "$DRIVERS_DIR/npm-global.sh"
    npm_global_check "f.o" && exit 1
    npm_global_check "foo" || exit 2
    exit 0
) && { passed=$((passed+1)); echo "  ✓ A2-F-009 npm_global_check uses --parseable literal lookup"; } \
   || { failed=$((failed+1)); echo "  ✗ A2-F-009 npm_global_check still regex-matches" >&2; }

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
