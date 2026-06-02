#!/usr/bin/env bash
# Unit tests for scripts/lib/secrets-crypt.sh (git-crypt wiring + pre-commit guard).
# Bash 3.2 compatible. Tests the pure file logic + the FAIL-CLOSED guard branches
# (the security-critical paths). git-crypt-positive branches are exercised only
# where git-crypt is installed; the guard's "tool absent" branch is covered here.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"

pass=0; fail=0; fails=""
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); fails="$fails
  FAIL: $1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkrepo() {
    local r="$1"; mkdir -p "$r"
    ( cd "$r" && git init -q && git config user.email t@t && git config user.name t )
}

. "$WS/scripts/lib/secrets-crypt.sh"

# --- .gitattributes managed block (pure logic) ---
R="$TMP/r1"; mkrepo "$R"
secrets_crypt_attr_ok "$R" && no "attr_ok should be false on empty repo" || ok
secrets_crypt_attr_ensure "$R" && ok || no "attr_ensure should succeed"
secrets_crypt_attr_ok "$R" && ok || no "attr_ok true after ensure"
secrets_crypt_attr_ensure "$R" && ok || no "attr_ensure idempotent"
[ "$(grep -c 'secrets/\*\* filter=git-crypt' "$R/.gitattributes")" = "1" ] && ok \
    || no "exactly one rule line after double ensure"
grep -qF 'secrets/manifest.yaml !filter !diff' "$R/.gitattributes" && ok || no "manifest negation present"

# attr_ensure preserves pre-existing content
R1b="$TMP/r1b"; mkrepo "$R1b"
printf '*.bin binary\n' > "$R1b/.gitattributes"
secrets_crypt_attr_ensure "$R1b" && ok || no "attr_ensure with prior content"
grep -qF '*.bin binary' "$R1b/.gitattributes" && ok || no "prior content preserved"

# --- repo state detection ---
secrets_crypt_initialized "$R" && no "should NOT be initialized" || ok
mkdir -p "$R/.git/git-crypt/keys"
secrets_crypt_initialized "$R" && ok || no "initialized after .git/git-crypt"
secrets_crypt_unlocked "$R" && no "should NOT be unlocked without key" || ok
: > "$R/.git/git-crypt/keys/default"
secrets_crypt_unlocked "$R" && ok || no "unlocked after key file"

# --- init refuses without git-crypt (this host has none) ---
if ! secrets_crypt_available; then
    secrets_crypt_init "$TMP/r1" "$TMP/key" >/dev/null 2>&1
    [ $? -ne 0 ] && ok || no "init should fail when git-crypt absent"
    secrets_crypt_unlock "$TMP/r1" "$TMP/nope" >/dev/null 2>&1
    [ $? -ne 0 ] && ok || no "unlock should fail when git-crypt absent"
fi

# --- guard: nothing under secrets staged → safe ---
R2="$TMP/r2"; mkrepo "$R2"
echo hi > "$R2/readme"; ( cd "$R2" && git add readme )
secrets_crypt_guard "$R2" && ok || no "guard rc0 when no secrets staged"

# --- guard: only cleartext manifest staged → safe (no git-crypt required) ---
R4="$TMP/r4"; mkrepo "$R4"; secrets_crypt_attr_ensure "$R4"
mkdir -p "$R4/secrets"; echo 'version: 1' > "$R4/secrets/manifest.yaml"
( cd "$R4" && git add -f secrets/manifest.yaml )
secrets_crypt_guard "$R4" && ok || no "guard rc0 when only manifest staged"

# --- guard: real secret staged but NO attr rule → BLOCK ---
R3="$TMP/r3"; mkrepo "$R3"
mkdir -p "$R3/secrets"; echo 'TOKEN=abc' > "$R3/secrets/x.env"
( cd "$R3" && git add -f secrets/x.env )
secrets_crypt_guard "$R3" >/dev/null 2>&1 && no "guard must BLOCK without attr rule" || ok

# --- guard: real secret staged + attr rule but git-crypt absent → BLOCK ---
secrets_crypt_attr_ensure "$R3"
if ! secrets_crypt_available; then
    secrets_crypt_guard "$R3" >/dev/null 2>&1 && no "guard must BLOCK when git-crypt absent" || ok
fi

# --- summary ---
total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    printf 'secrets-crypt.test.sh: %d/%d PASS\n' "$pass" "$total"
    exit 0
else
    printf 'secrets-crypt.test.sh: %d/%d PASS, %d FAIL%b\n' "$pass" "$total" "$fail" "$fails"
    exit 1
fi
