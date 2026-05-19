#!/usr/bin/env bash
# Unit tests for managed-block.sh — splice between mesh-managed markers.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
LIB="$WS/scripts/lib/managed-block.sh"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected: '$expected', got: '$actual')" >&2; fi
}

. "$LIB"

# Test 1: inject block into empty file
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
touch "$TMP/target"
managed_block_apply "$TMP/target" "ssh-keys" <<'EOF'
ssh-rsa AAAA... user@host
EOF
expected="# >>> BEGIN mesh-managed: ssh-keys >>>
ssh-rsa AAAA... user@host
# <<< END mesh-managed: ssh-keys <<<"
actual=$(cat "$TMP/target")
assert "inject into empty" "$expected" "$actual"

# Test 2: re-apply with same content is idempotent (file unchanged)
hash_before=$(shasum "$TMP/target" | awk '{print $1}')
managed_block_apply "$TMP/target" "ssh-keys" <<'EOF'
ssh-rsa AAAA... user@host
EOF
hash_after=$(shasum "$TMP/target" | awk '{print $1}')
assert "re-apply idempotent" "$hash_before" "$hash_after"

# Test 3: case-insensitive marker match (mesh-managed: vs MESH-MANAGED:)
echo "# >>> BEGIN MESH-MANAGED: case-test >>>
old content
# <<< END MESH-MANAGED: case-test <<<" > "$TMP/case-target"
managed_block_apply "$TMP/case-target" "case-test" <<'EOF'
new content
EOF
got=$(grep -c "new content" "$TMP/case-target")
assert "case-insensitive match: replaced" "1" "$got"

# Test 4: old dotfiles-managed marker also matched (case-insensitive, L16 / bug-2026-04-23)
echo "# >>> BEGIN dotfiles-managed: legacy >>>
should-be-replaced
# <<< END dotfiles-managed: legacy <<<" > "$TMP/legacy-target"
managed_block_apply "$TMP/legacy-target" "legacy" <<'EOF'
fresh
PAD
EOF
got=$(grep -c 'mesh-managed: legacy' "$TMP/legacy-target")
assert "legacy marker upgraded to mesh-managed" "2" "$got"

# Test 5: block content with backslash characters is preserved verbatim (regression for re.sub backslash interp)
echo "" > "$TMP/backslash-target"
managed_block_apply "$TMP/backslash-target" "env" <<'EOF'
export PATH="$HOME/.local/bin:$PATH"
export PROMPT="\$ "
group_test=\1\2
EOF
got=$(cat "$TMP/backslash-target")
# Must contain the literal backslash sequences without re.error or corruption
if echo "$got" | grep -q 'group_test=\\1\\2'; then
    passed=$((passed+1)); echo "  ✓ backslash content preserved"
else
    failed=$((failed+1)); echo "  ✗ backslash content mangled or crash" >&2
fi

# ─── managed_block_in_sync (C12/D49) ────────────────────────────────
# These tests cover the helper that doctor.sh uses to detect drift in
# managed_block mappings. Uses literal dotfiles-managed: markers (matches
# install.sh's current writer) — see lib header for the case-insensitive
# follow-up note.

# Test 6: in_sync when dst contains the exact reconstructed block at EOF.
# managed_block protocol is append-only: install.sh always puts the block at
# the end of the file, so drift detection requires the block to be the last
# section. Header lines before the block are preserved untouched.
mkdir -p "$TMP/sync"
printf 'ssh-rsa AAAA user@host\n' > "$TMP/sync/src"
{
    printf '# header line\n'
    printf '# >>> BEGIN dotfiles-managed: ssh-keys >>>\n'
    printf 'ssh-rsa AAAA user@host\n'
    printf '# <<< END dotfiles-managed: ssh-keys <<<\n'
} > "$TMP/sync/dst"
if managed_block_in_sync "$TMP/sync/src" "$TMP/sync/dst" "ssh-keys"; then
    passed=$((passed+1)); echo "  ✓ in_sync: matching block returns 0"
else
    failed=$((failed+1)); echo "  ✗ in_sync should return 0 for matching block" >&2
fi

# Test 7: drift detected when dst block differs from src
printf 'ssh-rsa BBBB different@host\n' > "$TMP/sync/dst-drift-src"
{
    printf '# >>> BEGIN dotfiles-managed: ssh-keys >>>\n'
    printf 'ssh-rsa AAAA user@host\n'
    printf '# <<< END dotfiles-managed: ssh-keys <<<\n'
} > "$TMP/sync/dst-drift"
if managed_block_in_sync "$TMP/sync/dst-drift-src" "$TMP/sync/dst-drift" "ssh-keys"; then
    failed=$((failed+1)); echo "  ✗ in_sync should detect drift" >&2
else
    passed=$((passed+1)); echo "  ✓ in_sync: content mismatch returns 1"
fi

# Test 8: markers absent → return 1 (block never deployed)
printf 'no markers here\n' > "$TMP/sync/dst-no-markers"
if managed_block_in_sync "$TMP/sync/src" "$TMP/sync/dst-no-markers" "ssh-keys"; then
    failed=$((failed+1)); echo "  ✗ in_sync should return 1 when markers absent" >&2
else
    passed=$((passed+1)); echo "  ✓ in_sync: absent markers returns 1"
fi

# Test 9: header lines BEFORE the block are preserved across the check.
# Drift detection treats them as user-owned content outside the managed region.
{
    printf 'before line 1\n'
    printf 'before line 2\n'
    printf '# >>> BEGIN dotfiles-managed: env >>>\n'
    printf 'PATH=/usr/bin\n'
    printf '# <<< END dotfiles-managed: env <<<\n'
} > "$TMP/sync/dst-with-header"
printf 'PATH=/usr/bin\n' > "$TMP/sync/src-env"
if managed_block_in_sync "$TMP/sync/src-env" "$TMP/sync/dst-with-header" "env"; then
    passed=$((passed+1)); echo "  ✓ in_sync: header context preserved"
else
    failed=$((failed+1)); echo "  ✗ in_sync should tolerate header lines" >&2
fi

# Test 9b: trailing lines AFTER the block ARE drift — install.sh appends, so
# any non-block content past the END marker would be moved by a re-deploy.
{
    printf '# >>> BEGIN dotfiles-managed: env >>>\n'
    printf 'PATH=/usr/bin\n'
    printf '# <<< END dotfiles-managed: env <<<\n'
    printf 'rogue trailing line\n'
} > "$TMP/sync/dst-with-trailing"
if managed_block_in_sync "$TMP/sync/src-env" "$TMP/sync/dst-with-trailing" "env"; then
    failed=$((failed+1)); echo "  ✗ in_sync should flag trailing content as drift" >&2
else
    passed=$((passed+1)); echo "  ✓ in_sync: trailing content after block is drift"
fi

# Test 10: src with no trailing newline still matches (print_with_eol mirror)
printf 'one-liner-no-newline' > "$TMP/sync/src-noeol"
{
    printf '# >>> BEGIN dotfiles-managed: liner >>>\n'
    printf 'one-liner-no-newline\n'
    printf '# <<< END dotfiles-managed: liner <<<\n'
} > "$TMP/sync/dst-liner"
if managed_block_in_sync "$TMP/sync/src-noeol" "$TMP/sync/dst-liner" "liner"; then
    passed=$((passed+1)); echo "  ✓ in_sync: src without trailing newline matches"
else
    failed=$((failed+1)); echo "  ✗ in_sync should append newline for non-EOL src" >&2
fi

# Test 11 (CP4 A1-F-002): apply refuses to write when destination has
# orphan BEGIN marker (no matching END) for the same slot.
mkdir -p "$TMP/orphan"
cat > "$TMP/orphan/dst" <<'ORPHAN'
some-existing-content
# >>> BEGIN mesh-managed: foo >>>
old block content
# (note: NO matching END marker — file is broken)
more-content-after-orphan
ORPHAN
pre_sha=$(shasum "$TMP/orphan/dst" | awk '{print $1}')
set +e
err_output=$(echo "new content" | managed_block_apply "$TMP/orphan/dst" "foo" 2>&1)
rc=$?
set -e
post_sha=$(shasum "$TMP/orphan/dst" | awk '{print $1}')
if [[ "$rc" == "2" ]] && [[ "$pre_sha" == "$post_sha" ]] && [[ "$err_output" == *"malformed markers"* ]]; then
    passed=$((passed+1)); echo "  ✓ A1-F-002: apply refuses orphan BEGIN (rc=2, no write)"
else
    failed=$((failed+1)); echo "  ✗ A1-F-002: apply did not refuse orphan BEGIN (rc=$rc, pre=$pre_sha post=$post_sha)" >&2
fi

# Test 12 (CP4 A1-F-002): apply refuses orphan END marker too
cat > "$TMP/orphan/dst-end-only" <<'ORPHAN'
some-existing-content
# <<< END mesh-managed: foo <<<
content-after-orphan-end
ORPHAN
pre_sha=$(shasum "$TMP/orphan/dst-end-only" | awk '{print $1}')
set +e
err_output=$(echo "new content" | managed_block_apply "$TMP/orphan/dst-end-only" "foo" 2>&1)
rc=$?
set -e
post_sha=$(shasum "$TMP/orphan/dst-end-only" | awk '{print $1}')
if [[ "$rc" == "2" ]] && [[ "$pre_sha" == "$post_sha" ]] && [[ "$err_output" == *"malformed markers"* ]]; then
    passed=$((passed+1)); echo "  ✓ A1-F-002: apply refuses orphan END (rc=2, no write)"
else
    failed=$((failed+1)); echo "  ✗ A1-F-002: apply did not refuse orphan END (rc=$rc)" >&2
fi

# Test 13 (CP4 A1-F-002): unmatched counts (2 BEGINs, 1 END) is also refused
cat > "$TMP/orphan/dst-double-begin" <<'ORPHAN'
# >>> BEGIN mesh-managed: foo >>>
content-1
# >>> BEGIN mesh-managed: foo >>>
content-2
# <<< END mesh-managed: foo <<<
ORPHAN
pre_sha=$(shasum "$TMP/orphan/dst-double-begin" | awk '{print $1}')
set +e
err_output=$(echo "new content" | managed_block_apply "$TMP/orphan/dst-double-begin" "foo" 2>&1)
rc=$?
set -e
post_sha=$(shasum "$TMP/orphan/dst-double-begin" | awk '{print $1}')
if [[ "$rc" == "2" ]] && [[ "$pre_sha" == "$post_sha" ]] && [[ "$err_output" == *"malformed markers"* ]]; then
    passed=$((passed+1)); echo "  ✓ A1-F-002: apply refuses mismatched BEGIN/END counts (rc=2, no write)"
else
    failed=$((failed+1)); echo "  ✗ A1-F-002: apply did not refuse mismatched counts (rc=$rc)" >&2
fi

# Tests 14-16 (CP4 D-F-001): managed_block_in_sync must match BOTH
# legacy `dotfiles-managed:` and canonical `mesh-managed:` markers
# because the writer migrates dotfiles → mesh in place on every run.
mkdir -p "$TMP/dual"
# 14a: canonical mesh-managed: in dst, src matches → in sync
cat > "$TMP/dual/src-mesh" <<'SRC'
content-line-1
content-line-2
SRC
cat > "$TMP/dual/dst-mesh" <<'DST'
header
# >>> BEGIN mesh-managed: dual-mesh >>>
content-line-1
content-line-2
# <<< END mesh-managed: dual-mesh <<<
DST
if managed_block_in_sync "$TMP/dual/src-mesh" "$TMP/dual/dst-mesh" "dual-mesh"; then
    passed=$((passed+1)); echo "  ✓ D-F-001: in_sync accepts canonical mesh-managed: markers"
else
    failed=$((failed+1)); echo "  ✗ D-F-001: in_sync rejected canonical mesh-managed: markers" >&2
fi

# 14b: legacy dotfiles-managed: in dst, src matches → in sync
cat > "$TMP/dual/dst-legacy" <<'DST'
header
# >>> BEGIN dotfiles-managed: dual-legacy >>>
content-line-1
content-line-2
# <<< END dotfiles-managed: dual-legacy <<<
DST
cat > "$TMP/dual/src-legacy" <<'SRC'
content-line-1
content-line-2
SRC
if managed_block_in_sync "$TMP/dual/src-legacy" "$TMP/dual/dst-legacy" "dual-legacy"; then
    passed=$((passed+1)); echo "  ✓ D-F-001: in_sync still accepts legacy dotfiles-managed: markers"
else
    failed=$((failed+1)); echo "  ✗ D-F-001: in_sync rejected legacy markers" >&2
fi

# 14c: dst has the canonical block but src content DIFFERS → drift
cat > "$TMP/dual/dst-drift-canon" <<'DST'
# >>> BEGIN mesh-managed: dual-drift >>>
stale-content
# <<< END mesh-managed: dual-drift <<<
DST
cat > "$TMP/dual/src-drift" <<'SRC'
fresh-content
SRC
if managed_block_in_sync "$TMP/dual/src-drift" "$TMP/dual/dst-drift-canon" "dual-drift"; then
    failed=$((failed+1)); echo "  ✗ D-F-001: in_sync wrongly accepted drift in canonical block" >&2
else
    passed=$((passed+1)); echo "  ✓ D-F-001: in_sync correctly detects drift in canonical block"
fi

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
