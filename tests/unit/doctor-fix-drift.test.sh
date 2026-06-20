#!/usr/bin/env bash
# Unit tests for `doctor.sh --fix` — re-syncing identity deploy drift.
#
# Gap (2026-06-17): `mesh doctor` detected deploy drift but `mesh doctor --fix`
# only ran setup.sh --repair (broken installs/services), never re-deploying the
# drifted config. Drift could only be healed by manually running install.sh.
# `doctor.sh --fix` now re-runs deploy_one on each drifted/missing mapping, and
# the read-only drift message points at `mesh doctor --fix` instead of install.sh.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
DOCTOR="$WS/scripts/runners/doctor.sh"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected: '$expected', got: '$actual')" >&2; fi
}
ok()  { passed=$((passed+1)); echo "  ✓ $1"; }
bad() { failed=$((failed+1)); echo "  ✗ $1" >&2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/empty-ld"   # empty LaunchDaemons dir → no phantom noise

field() { echo "$1" | grep -oE "\"$2\":[0-9]+" | head -1 | cut -d: -f2; }
# Run doctor.sh against sandbox identity $ID, markers/launchd neutralized.
doc() {
    MESH_IDENTITY_DIR="$ID" DOCTOR_MARKER_FILES="$TMP/no-marker" \
    DOCTOR_LAUNCHD_DIR="$TMP/empty-ld" NO_COLOR=1 \
        bash "$DOCTOR" "$@" 2>/dev/null || true
}

# ── Test 1 [regression: overwrite drift heal] ───────────────────────
ID="$TMP/id1"; mkdir -p "$ID/conf"; home="$TMP/home1"; mkdir -p "$home"
printf 'conf/sample | %s/.sample | overwrite | 0644\n' "$home" > "$ID/deploy.map"
printf 'REAL v2\n'  > "$ID/conf/sample"
printf 'OLD drift\n' > "$home/.sample"
before=$(field "$(doc --json)" drift)
out=$(doc --fix --json)
assert "[overwrite] drift before fix" "1" "$before"
assert "[overwrite] dst healed to src content" "REAL v2" "$(cat "$home/.sample")"
assert "[overwrite] drift after fix" "0" "$(field "$out" drift)"
assert "[overwrite] re-synced counted" "1" "$(field "$out" fixed)"

# ── Test 2 [managed_block drift heal] ───────────────────────────────
ID="$TMP/id2"; mkdir -p "$ID/ssh"; home="$TMP/home2"; mkdir -p "$home/.ssh"
printf 'ssh/authorized_keys | %s/.ssh/authorized_keys | managed_block | 0600\n' "$home" > "$ID/deploy.map"
printf 'ssh-ed25519 AAAAreal me@host\n' > "$ID/ssh/authorized_keys"
{
    printf '# >>> BEGIN mesh-managed: ssh/authorized_keys >>>\n'
    printf 'ssh-ed25519 AAAAstale old@host\n'
    printf '# <<< END mesh-managed: ssh/authorized_keys <<<\n'
} > "$home/.ssh/authorized_keys"
before=$(field "$(doc --json)" drift)
doc --fix >/dev/null 2>&1
assert "[managed_block] drift before fix" "1" "$before"
assert "[managed_block] in sync after fix" "0" "$(field "$(doc --json)" drift)"
if grep -q 'AAAAreal me@host' "$home/.ssh/authorized_keys"; then
    ok "[managed_block] real key spliced into block"
else
    bad "[managed_block] real key not spliced"
fi

# ── Test 3 [missing dst is created] ─────────────────────────────────
ID="$TMP/id3"; mkdir -p "$ID/conf"; home="$TMP/home3"; mkdir -p "$home"
printf 'conf/x | %s/.x | overwrite | 0644\n' "$home" > "$ID/deploy.map"
printf 'XCONTENT\n' > "$ID/conf/x"   # dst intentionally absent
before=$(field "$(doc --json)" missing)
doc --fix >/dev/null 2>&1
assert "[missing] missing before fix" "1" "$before"
assert "[missing] missing after fix" "0" "$(field "$(doc --json)" missing)"
if [[ -f "$home/.x" ]]; then ok "[missing] dst created by fix"; else bad "[missing] dst not created"; fi

# ── Test 4 [clean mapping is a no-op under --fix] ───────────────────
ID="$TMP/id4"; mkdir -p "$ID/conf"; home="$TMP/home4"; mkdir -p "$home"
printf 'conf/c | %s/.c | overwrite | 0644\n' "$home" > "$ID/deploy.map"
printf 'SAME\n' > "$ID/conf/c"; printf 'SAME\n' > "$home/.c"
out=$(doc --fix --json)
assert "[clean] drift stays 0 under fix" "0" "$(field "$out" drift)"
assert "[clean] nothing re-synced" "0" "$(field "$out" fixed)"

# ── Test 5 [C2: drift message points at the self-heal command] ──────
ID="$TMP/id5"; mkdir -p "$ID/conf"; home="$TMP/home5"; mkdir -p "$home"
printf 'conf/m | %s/.m | overwrite | 0644\n' "$home" > "$ID/deploy.map"
printf 'NEW\n' > "$ID/conf/m"; printf 'OLD\n' > "$home/.m"
msg=$(doc)   # human output, no --fix
if echo "$msg" | grep -q "mesh doctor --fix"; then ok "[C2] drift message names 'mesh doctor --fix'"; else bad "[C2] drift message missing 'mesh doctor --fix'"; fi
if echo "$msg" | grep -q "run install.sh to sync"; then bad "[C2] message still says raw 'run install.sh to sync'"; else ok "[C2] raw install.sh wording removed"; fi

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
