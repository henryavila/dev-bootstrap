#!/usr/bin/env bash
# Unit tests for deploy_map_emit() + deploy_map() — the deploy.map data-file
# front end to deploy_one (audit T-001). Covers parsing, comment/blank skip,
# default mode/perms, ~/$HOME/$USER expansion, malformed-line handling, the
# empty-field-with-pipes form, and end-to-end deploy.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
. "$WS/scripts/lib/deploy.sh"

passed=0; failed=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ID="$TMP/identity"; mkdir -p "$ID/shell" "$ID/git"
echo "alias-content" > "$ID/shell/aliases.sh"
echo "git-content"   > "$ID/git/gitconfig.local"
export HOME="$TMP/home"; export USER="tester"; mkdir -p "$HOME"

ok()   { passed=$((passed+1)); echo "  ✓ $1"; }
no()   { failed=$((failed+1)); echo "  ✗ $1" >&2; }

# ── deploy_map_emit: parsing + normalization ────────────────────────────────
cat > "$ID/deploy.map" <<'MAP'
# a comment
   # indented comment

shell/aliases.sh | ~/.aliases.sh
git/gitconfig.local | $HOME/.gitconfig.local | once
shell/aliases.sh | ~/.ssh/x | | 0600
shell/aliases.sh | ${HOME}/.u/$USER.conf | overwrite | 0644
  badline-without-pipe
| only-dst-empty-src
MAP

emit="$(deploy_map_emit "$ID/deploy.map" 2>"$TMP/emit.err")"

# Test 1: comments + blank lines skipped, 4 valid rows emitted
n=$(printf '%s\n' "$emit" | grep -c .)
if [[ "$n" == "4" ]]; then ok "emit yields 4 rows (comments/blanks skipped)"
else no "emit row count = $n (want 4)"; fi

# Test 2: ~ expands to $HOME, fields trimmed, empty mode/perms preserved as empty
if printf '%s\n' "$emit" | grep -qxF "shell/aliases.sh|$HOME/.aliases.sh||"; then ok "~ → \$HOME, trimmed, defaults left empty"
else no "tilde-expansion row wrong: $(printf '%s\n' "$emit" | head -1)"; fi

# Test 3: $HOME and mode carried
if printf '%s\n' "$emit" | grep -qxF "git/gitconfig.local|$HOME/.gitconfig.local|once|"; then ok "\$HOME expand + mode carried"
else no "\$HOME/mode row wrong"; fi

# Test 4: empty-field-with-pipes form (src|dst||perms) → mode empty, perms kept
if printf '%s\n' "$emit" | grep -qxF "shell/aliases.sh|$HOME/.ssh/x||0600"; then ok "empty mode w/ explicit perms parsed"
else no "empty-mode-w-perms row wrong"; fi

# Test 5: ${HOME} and $USER both expand
if printf '%s\n' "$emit" | grep -qxF "shell/aliases.sh|$HOME/.u/tester.conf|overwrite|0644"; then ok "\${HOME} + \$USER expand"
else no "\${HOME}/\$USER row wrong"; fi

# Test 6: malformed lines (no pipe / empty src) warned + skipped
if grep -q 'malformed deploy.map line' "$TMP/emit.err"; then ok "malformed lines warned to stderr"
else no "malformed lines not warned"; fi

# Test 7: unreadable map → non-zero
if deploy_map_emit "$ID/nope.map" >/dev/null 2>&1; then no "unreadable map should fail"
else ok "unreadable map returns non-zero"; fi

# ── deploy_map: end-to-end deploy ───────────────────────────────────────────
cat > "$ID/deploy2.map" <<'MAP'
shell/aliases.sh | ~/.aliases.sh
git/gitconfig.local | ~/.gitconfig.local | once | 0600
MAP
deploy_map "$ID/deploy2.map" "$ID" >/dev/null 2>&1

# Test 8: overwrite entry deployed with expanded dst
if [[ "$(cat "$HOME/.aliases.sh" 2>/dev/null)" == "alias-content" ]]; then ok "deploy_map deploys overwrite entry"
else no "overwrite entry not deployed"; fi

# Test 9: once entry deployed + perms applied
if [[ -f "$HOME/.gitconfig.local" ]]; then
  m=$(stat -c '%a' "$HOME/.gitconfig.local" 2>/dev/null || stat -f '%Lp' "$HOME/.gitconfig.local" 2>/dev/null)
  if [[ "$m" == "600" ]]; then ok "once entry deployed with perms 0600"
  else no "once entry perms = $m (want 600)"; fi
else no "once entry not deployed"; fi

# Test 10: a failing entry (missing source) makes deploy_map return non-zero,
# but other entries still deploy (all attempted).
cat > "$ID/deploy3.map" <<'MAP'
does/not/exist | ~/.willfail
shell/aliases.sh | ~/.after-fail.sh
MAP
rc=0; deploy_map "$ID/deploy3.map" "$ID" >/dev/null 2>&1 || rc=$?
if [[ "$rc" != "0" ]] && [[ -f "$HOME/.after-fail.sh" ]]; then ok "deploy_map: rc!=0 on failure yet later entries still attempted"
else no "deploy_map failure handling wrong (rc=$rc, after-fail exists=$([[ -f $HOME/.after-fail.sh ]] && echo y || echo n))"; fi

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
