#!/usr/bin/env bash
# Unit tests for scripts/lib/secret.sh — the `mesh secret` CLI (non-interactive
# verbs: list / deploy / doctor / dispatch). Interactive verbs (add/set/rm) and
# git-crypt-positive paths need a TTY + git-crypt and are covered by runtime test.
# Bash 3.2 compatible. Isolates $HOME + PATH so composer-home falls back
# deterministically and we never touch the real ~/.composer.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
SECRET="$WS/scripts/lib/secret.sh"

pass=0; fail=0; fails=""
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); fails="$fails
  FAIL: $1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME"
ID="$TMP/identity"; mkdir -p "$ID/secrets/composer"
cat > "$ID/secrets/manifest.yaml" <<'EOF'
version: 1
integrations:
  composer-auth:
    tier: 2
    type: file
    source: secrets/composer/auth.json
    dest_resolver: composer-home
    dest_file: auth.json
    perms: "0600"
  gh:
    tier: 1
    type: login
    check: false
    login: echo would-run-login
  anthropic:
    tier: 2
    type: env-token
    key: ANTHROPIC_API_KEY
EOF
printf '{"http-basic":{}}\n' > "$ID/secrets/composer/auth.json"
printf '# env-token store\nexport ANTHROPIC_API_KEY=sk-test-xyz\n' > "$ID/secrets/secrets.env"

# Fake composer (first on PATH) returns a controlled home with NO side effects,
# so the composer-home resolver is deterministic regardless of the host's real
# composer (git + composer often share a brew bin, so PATH alone can't exclude it).
GITDIR="$(dirname "$(command -v git)")"
mkdir -p "$TMP/bin" "$FAKE_HOME/.composer"
cat > "$TMP/bin/composer" <<EOF
#!/usr/bin/env bash
[ "\$1" = "config" ] && { echo "$FAKE_HOME/.composer"; exit 0; }
exit 0
EOF
chmod +x "$TMP/bin/composer"
run() { HOME="$FAKE_HOME" MESH_IDENTITY_DIR="$ID" PATH="$TMP/bin:/usr/bin:/bin:$GITDIR" bash "$SECRET" "$@"; }

# --- list ---
out="$(run list 2>&1)"
printf '%s' "$out" | grep -q "composer-auth" && ok || no "list shows composer-auth"
printf '%s' "$out" | grep -q "gh" && ok || no "list shows gh"
printf '%s' "$out" | grep -q "ready" && ok || no "list shows file status 'ready'"

# --- deploy: composer auth.json lands in the resolved composer home ---
run deploy >/dev/null 2>&1
DEST="$FAKE_HOME/.composer/auth.json"
[ -f "$DEST" ] && ok || no "deploy created $DEST"
[ "$(cat "$DEST" 2>/dev/null)" = '{"http-basic":{}}' ] && ok || no "deployed content matches"
# env-token store deployed to the engine's runtime path
EDST="$FAKE_HOME/.local/state/mesh/secrets.env"
[ -f "$EDST" ] && ok || no "deploy wrote env-token store to $EDST"
grep -q "ANTHROPIC_API_KEY" "$EDST" 2>/dev/null && ok || no "deployed env store contains the token"

# idempotent re-deploy: identical content → no .bak created
run deploy >/dev/null 2>&1
[ -z "$(ls "$FAKE_HOME/.composer/"*.bak-* 2>/dev/null)" ] && ok || no "idempotent deploy made no backup"

# --- deploy: changed canonical → backup + overwrite (user's chosen semantics) ---
printf '{"http-basic":{"x":1}}\n' > "$ID/secrets/composer/auth.json"
run deploy >/dev/null 2>&1
[ -n "$(ls "$FAKE_HOME/.composer/"*.bak-* 2>/dev/null)" ] && ok || no "changed canonical made a backup"
grep -q '"x":1' "$DEST" && ok || no "changed content deployed"

# --- deploy: ciphertext source is skipped (repo locked) ---
printf '\000GITCRYPT\000ciphertextblob' > "$ID/secrets/composer/auth.json"
out="$(run deploy 2>&1)"
printf '%s' "$out" | grep -qi "unlock" && ok || no "locked source warns to unlock"

# --- doctor: reports unhealthy (git-crypt absent in this fixture) with rc!=0 ---
run doctor >/dev/null 2>&1
[ $? -ne 0 ] && ok || no "doctor rc!=0 when git-crypt not set up"

# --- dispatch: unknown verb → rc1 + usage ---
run definitely-not-a-verb >/dev/null 2>&1
[ $? -ne 0 ] && ok || no "unknown verb rc!=0"

# --- dispatch: help ---
run --help 2>&1 | grep -q "Usage: mesh secret" && ok || no "help prints usage"

# --- empty manifest → friendly list ---
EMPTY="$TMP/empty"; mkdir -p "$EMPTY/secrets"; printf 'version: 1\nintegrations:\n' > "$EMPTY/secrets/manifest.yaml"
HOME="$FAKE_HOME" MESH_IDENTITY_DIR="$EMPTY" PATH="/usr/bin:/bin:$GITDIR" bash "$SECRET" list 2>&1 | grep -qi "no integrations" && ok || no "empty manifest friendly message"

# --- base64 key export + unlock round-trip (real git-crypt only) ---
# The headline UX: password managers are text-only, so the key travels as base64.
if command -v git-crypt >/dev/null 2>&1; then
    . "$WS/scripts/lib/secrets-crypt.sh"
    A="$TMP/repoA"; mkdir -p "$A"
    ( cd "$A" && git init -q && git config user.email t@t && git config user.name t )
    secrets_crypt_attr_ensure "$A" >/dev/null
    ( cd "$A" && git-crypt init ) >/dev/null 2>&1
    mkdir -p "$A/secrets"; printf 'SECRET=topsecret\n' > "$A/secrets/k.env"
    ( cd "$A" && git add -f . && git commit -q -m seed )
    # export the key as base64 (stdout only; warnings go to stderr)
    B64="$(MESH_IDENTITY_DIR="$A" bash "$SECRET" export-key 2>/dev/null | tail -1)"
    [ -n "$B64" ] && ok || no "export-key produced a base64 string"
    # a fresh clone is LOCKED (secret is ciphertext)
    B="$TMP/repoB"; git clone -q "$A" "$B" 2>/dev/null
    [ "$(head -c 9 "$B/secrets/k.env" 2>/dev/null | tr -d '\000')" = "GITCRYPT" ] && ok || no "fresh clone is locked (ciphertext)"
    # unlock the clone with ONLY the base64 string → working tree becomes cleartext
    MESH_IDENTITY_DIR="$B" bash "$SECRET" unlock "$B64" >/dev/null 2>&1
    grep -q "SECRET=topsecret" "$B/secrets/k.env" 2>/dev/null && ok || no "unlock from base64 decrypted the clone"
fi

# --- summary ---
total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    printf 'secret-cli.test.sh: %d/%d PASS\n' "$pass" "$total"
    exit 0
else
    printf 'secret-cli.test.sh: %d/%d PASS, %d FAIL%b\n' "$pass" "$total" "$fail" "$fails"
    exit 1
fi
