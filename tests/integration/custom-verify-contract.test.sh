#!/usr/bin/env bash
# Regression: custom_verify must use verify()'s rc authoritatively when
# defined, falling back to check() ONLY when verify() is undefined.
# Codex review 2026-05-19 (A-F002): previous `verify || check` masked
# verify failures whenever the weaker check() still returned 0.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"

# shellcheck disable=SC1091
. "$WS/scripts/lib/installers/custom.sh"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected: $expected, got: $actual)" >&2; fi
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Case a: verify defined + passes ⇒ rc=0 (check() not consulted)
cat > "$TMP/a.sh" <<'SH'
check()  { return 1; }   # would fail; must NOT be reached
verify() { return 0; }
SH
chmod +x "$TMP/a.sh"
set +e; custom_verify "$TMP/a.sh"; rc=$?; set -e
assert "a: verify passes ⇒ rc=0 (check ignored)" "0" "$rc"

# Case b: verify defined + fails ⇒ rc!=0 (REGRESSION for A-F002)
# Previously, a failing verify followed by a passing check returned 0.
cat > "$TMP/b.sh" <<'SH'
check()  { return 0; }   # would mask verify failure under old code
verify() { return 1; }
SH
chmod +x "$TMP/b.sh"
set +e; custom_verify "$TMP/b.sh"; rc=$?; set -e
[[ $rc -ne 0 ]] && { passed=$((passed+1)); echo "  ✓ b: verify fails ⇒ rc!=0 (no fallback to check)"; } \
                || { failed=$((failed+1)); echo "  ✗ b: verify failure masked by check (rc=$rc) — A-F002 regression" >&2; }

# Case c: verify absent + check passes ⇒ rc=0
cat > "$TMP/c.sh" <<'SH'
check() { return 0; }
SH
chmod +x "$TMP/c.sh"
set +e; custom_verify "$TMP/c.sh"; rc=$?; set -e
assert "c: no verify, check passes ⇒ rc=0" "0" "$rc"

# Case d: verify absent + check absent ⇒ rc=0 (engine has no contract to test)
cat > "$TMP/d.sh" <<'SH'
:
SH
chmod +x "$TMP/d.sh"
set +e; custom_verify "$TMP/d.sh"; rc=$?; set -e
assert "d: neither verify nor check defined ⇒ rc=0" "0" "$rc"

# Case e: verify absent + check fails ⇒ rc!=0
cat > "$TMP/e.sh" <<'SH'
check() { return 1; }
SH
chmod +x "$TMP/e.sh"
set +e; custom_verify "$TMP/e.sh"; rc=$?; set -e
[[ $rc -ne 0 ]] && { passed=$((passed+1)); echo "  ✓ e: no verify, check fails ⇒ rc!=0"; } \
                || { failed=$((failed+1)); echo "  ✗ e: check failure not propagated (rc=$rc)" >&2; }

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
