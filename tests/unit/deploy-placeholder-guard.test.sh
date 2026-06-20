#!/usr/bin/env bash
# Unit tests for deploy_one()'s scaffold-placeholder guard.
#
# Root cause (2026-06-17): a deploy run from a half-scaffolded identity dir
# (init.sh substitutes __USER_NAME__/__USER_EMAIL__/__GH_USERNAME__ but NOT
# the SSH pubkey token __REPLACE_WITH_YOUR_PUBLIC_KEY__) spliced the template
# placeholder into a live ~/.ssh/authorized_keys, wiping every real key and
# locking the host out. deploy_one had no guard against deploying an unfilled
# placeholder. The guard refuses (rc=2) so a scaffold can never clobber a
# deployed host; the next deploy from a filled source self-heals.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
. "$WS/scripts/lib/deploy.sh"

passed=0; failed=0
ok()  { passed=$((passed+1)); echo "  ✓ $1"; }
bad() { failed=$((failed+1)); echo "  ✗ $1" >&2; }
sha() { shasum "$1" | awk '{print $1}'; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

PLACEHOLDER='ssh-ed25519 AAAA__REPLACE_WITH_YOUR_PUBLIC_KEY__ parityuser@host'

# A scaffold identity dir whose ssh/authorized_keys still holds the placeholder.
mkdir -p "$TMP/scaffold/ssh"
{
    printf '# mesh-managed: ssh-authorized-keys start\n'
    printf '%s\n' "$PLACEHOLDER"
    printf '# mesh-managed: ssh-authorized-keys end\n'
} > "$TMP/scaffold/ssh/authorized_keys"

# ── Test 1 [regression]: managed_block deploy of a placeholder source is
# refused (rc=2) and the live dst (real keys) is left byte-for-byte intact.
dst="$TMP/live-authorized_keys"
{
    printf '# >>> BEGIN mesh-managed: ssh/authorized_keys >>>\n'
    printf 'ssh-ed25519 AAAArealkeybody realuser@host\n'
    printf '# <<< END mesh-managed: ssh/authorized_keys <<<\n'
} > "$dst"
pre=$(sha "$dst")
err=$(deploy_one "ssh/authorized_keys|$dst|managed_block|0600" "$TMP/scaffold" 2>&1) && rc=$? || rc=$?
post=$(sha "$dst")
if [[ "$rc" == "2" && "$pre" == "$post" && "$err" == *placeholder* ]]; then
    ok "[regression] managed_block refuses placeholder source (rc=2, dst intact)"
else
    bad "[regression] expected rc=2 + intact dst (rc=$rc, pre=$pre post=$post, err='$err')"
fi

# ── Test 2 [partition: happy]: a REAL managed_block source deploys normally —
# the guard must not block legitimate content.
mkdir -p "$TMP/real/ssh"
printf 'ssh-ed25519 AAAArealbody me@host\n' > "$TMP/real/ssh/authorized_keys"
dst2="$TMP/dst2-real"
err=$(deploy_one "ssh/authorized_keys|$dst2|managed_block|0600" "$TMP/real" 2>&1) && rc=$? || rc=$?
if [[ "$rc" == "0" ]] && grep -q 'AAAArealbody me@host' "$dst2" 2>/dev/null \
   && grep -q 'mesh-managed: ssh/authorized_keys' "$dst2" 2>/dev/null; then
    ok "[happy] real source deploys (rc=0, block written)"
else
    bad "[happy] real source should deploy (rc=$rc, err='$err')"
fi

# ── Test 3 [similar: overwrite]: placeholder source in overwrite mode is also
# refused, dst untouched. Same footgun, different mode.
printf 'placeholder __REPLACE_WITH_YOUR_PUBLIC_KEY__ here\n' > "$TMP/scaffold/ow-src"
dst3="$TMP/dst3-ow"; printf 'real existing content\n' > "$dst3"
pre3=$(sha "$dst3")
err=$(deploy_one "ow-src|$dst3|overwrite|0644" "$TMP/scaffold" 2>&1) && rc=$? || rc=$?
post3=$(sha "$dst3")
if [[ "$rc" == "2" && "$pre3" == "$post3" ]]; then
    ok "[overwrite] placeholder source refused, dst intact"
else
    bad "[overwrite] expected rc=2 + intact dst (rc=$rc, pre=$pre3 post=$post3)"
fi

# ── Test 4 [similar: once]: placeholder source in once mode does NOT seed a new
# file — refuse before creating dst.
printf 'x __REPLACE_WITH_YOUR_PUBLIC_KEY__\n' > "$TMP/scaffold/once-src"
dst4="$TMP/dst4-once"   # absent
err=$(deploy_one "once-src|$dst4|once|0644" "$TMP/scaffold" 2>&1) && rc=$? || rc=$?
if [[ "$rc" == "2" && ! -e "$dst4" ]]; then
    ok "[once] placeholder source refused, dst not created"
else
    bad "[once] expected rc=2 + no dst (rc=$rc, exists=$([[ -e "$dst4" ]] && echo yes || echo no))"
fi

# ── Test 5 [edge: substring]: real keys PLUS one stray placeholder line is still
# refused — detection is content-substring, not whole-file-equals.
mkdir -p "$TMP/mixed/ssh"
{
    printf 'ssh-ed25519 AAAArealbody me@host\n'
    printf 'ssh-ed25519 AAAA__REPLACE_WITH_YOUR_PUBLIC_KEY__ leftover@host\n'
} > "$TMP/mixed/ssh/authorized_keys"
dst5="$TMP/dst5-mixed"
{
    printf '# >>> BEGIN mesh-managed: ssh/authorized_keys >>>\n'
    printf 'ssh-ed25519 AAAAreal2 r@h\n'
    printf '# <<< END mesh-managed: ssh/authorized_keys <<<\n'
} > "$dst5"
pre5=$(sha "$dst5")
err=$(deploy_one "ssh/authorized_keys|$dst5|managed_block|0600" "$TMP/mixed" 2>&1) && rc=$? || rc=$?
post5=$(sha "$dst5")
if [[ "$rc" == "2" && "$pre5" == "$post5" ]]; then
    ok "[substring] stray placeholder line among real keys is refused"
else
    bad "[substring] expected rc=2 + intact dst (rc=$rc, pre=$pre5 post=$post5)"
fi

# ── Test 6 [mutation: no false positive]: a real source containing an unrelated
# double-underscore token (e.g. __pycache__) deploys fine. Guards against a
# fix that matched any __TOKEN__ instead of the exact sentinel.
mkdir -p "$TMP/fp"
printf 'cache_dir = /var/cache/__pycache__/objects\n' > "$TMP/fp/profile"
dst6="$TMP/dst6-fp"
err=$(deploy_one "profile|$dst6|overwrite|0644" "$TMP/fp" 2>&1) && rc=$? || rc=$?
if [[ "$rc" == "0" ]] && grep -q '__pycache__' "$dst6" 2>/dev/null; then
    ok "[no-false-positive] unrelated __token__ deploys (rc=0)"
else
    bad "[no-false-positive] __pycache__ must not trip the guard (rc=$rc, err='$err')"
fi

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
