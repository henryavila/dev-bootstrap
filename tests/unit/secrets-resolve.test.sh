#!/usr/bin/env bash
# Unit tests for scripts/lib/secrets-resolve.sh (Tier-2 file dest resolver).
# Bash 3.2 compatible. Uses a fake $HOME and PATH so verdicts are deterministic.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"

pass=0; fail=0; fails=""
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); fails="$fails
  FAIL: $1"; }
eq() { if [ "$2" = "$3" ]; then ok; else no "$1 (want '$3', got '$2')"; fi; }

# Isolate environment.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin"
unset COMPOSER_HOME XDG_CONFIG_HOME NPM_CONFIG_USERCONFIG 2>/dev/null || true
# Isolated PATH: fake bin first (for the authoritative-composer case), then the
# system coreutils dirs — which do NOT contain composer, so the fallback chain
# is exercised deterministically regardless of the host's real composer install.
export PATH="$TMP/bin:/usr/bin:/bin"

. "$WS/scripts/lib/secrets-resolve.sh"

# --- resolver list ---
eq "resolver count" "$(secrets_resolver_list | wc -l | tr -d ' ')" "4"

# --- composer-home fallback: no composer, no env, no ~/.composer → XDG ---
eq "composer xdg fallback" "$(secrets_resolve_home composer-home)" "$HOME/.config/composer"

# --- composer-home: ~/.composer exists (legacy) wins over XDG ---
mkdir -p "$HOME/.composer"
eq "composer legacy dir" "$(secrets_resolve_home composer-home)" "$HOME/.composer"

# --- composer-home: COMPOSER_HOME env wins over legacy dir ---
( export COMPOSER_HOME="$TMP/custom-composer"
  eq "composer env override" "$(secrets_resolve_home composer-home)" "$TMP/custom-composer" )

# --- composer-home: real composer binary is authoritative ---
cat > "$TMP/bin/composer" <<EOF
#!/usr/bin/env bash
[ "\$1" = "config" ] && { echo "$TMP/from-composer"; exit 0; }
exit 1
EOF
chmod +x "$TMP/bin/composer"
eq "composer binary authoritative" "$(secrets_resolve_home composer-home)" "$TMP/from-composer"
rm -f "$TMP/bin/composer"

# --- other resolvers ---
eq "xdg-config default" "$(secrets_resolve_home xdg-config)" "$HOME/.config"
( export XDG_CONFIG_HOME="$TMP/xdg"
  eq "xdg-config env" "$(secrets_resolve_home xdg-config)" "$TMP/xdg" )
eq "home resolver" "$(secrets_resolve_home home)" "$HOME"
eq "npm-home default" "$(secrets_resolve_home npm-home)" "$HOME"

# --- unknown resolver → rc 2 ---
secrets_resolve_home bogus >/dev/null 2>&1
[ $? -eq 2 ] && ok || no "unknown resolver should rc 2"

# --- secrets_dest_path: resolver + file ---
eq "dest via resolver" "$(secrets_dest_path '' composer-home auth.json)" "$HOME/.composer/auth.json"

# --- secrets_dest_path: absolute path with ~ ---
# shellcheck disable=SC2088  # literal ~ is the test input under expansion
eq "dest ~ expand" "$(secrets_dest_path '~/.npmrc' '' '')" "$HOME/.npmrc"

# --- secrets_dest_path: absolute path with $HOME ---
eq "dest \$HOME expand" "$(secrets_dest_path '$HOME/.s3cfg' '' '')" "$HOME/.s3cfg"

# --- secrets_dest_path: both forms set → rc 2 ---
# shellcheck disable=SC2088  # literal ~ is the test input under expansion
secrets_dest_path '~/.x' composer-home auth.json >/dev/null 2>&1
[ $? -eq 2 ] && ok || no "both dest forms should rc 2"

# --- secrets_dest_path: neither form → rc 2 ---
secrets_dest_path '' '' '' >/dev/null 2>&1
[ $? -eq 2 ] && ok || no "no dest form should rc 2"

# --- secrets_dest_path: resolver without file → rc 2 ---
secrets_dest_path '' composer-home '' >/dev/null 2>&1
[ $? -eq 2 ] && ok || no "resolver without file should rc 2"

# --- summary ---
total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    printf 'secrets-resolve.test.sh: %d/%d PASS\n' "$pass" "$total"
    exit 0
else
    printf 'secrets-resolve.test.sh: %d/%d PASS, %d FAIL%b\n' "$pass" "$total" "$fail" "$fails"
    exit 1
fi
