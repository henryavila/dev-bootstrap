#!/usr/bin/env bash
# Fail-fast / circuit-breaker contract for WSL rust-bins installer.
# Root cause of CRC hang: nested API+curl retries looked like a resolve/download
# loop on dust. Guards must bound downloads across custom_install re-sources
# (fresh `( . script; install )` subshells), not only within one sourced shell.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
SCRIPT="$WS/topics/shell-terminal/wsl/install-rust-bins.sh"
REAL_GH_API="$WS/scripts/lib/github-api.sh"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected: [$expected], got: [$actual])" >&2; fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/.local/bin" "$TMP/scripts/lib"
export HOME="$TMP/home"
export TMPDIR="$TMP"
# Prefer fake curl; keep system bins for mktemp/tar/install but NOT host dust/xh/procs.
export PATH="$TMP/bin:/usr/bin:/bin"
export MESH_WORKSTATION_DIR="$TMP"
export MESH_CURL_LOG="$TMP/curl.log"
export MESH_RUST_BINS_ATTEMPT_TTL=120
: > "$MESH_CURL_LOG"
: > "$TMP/gh_calls"

# Minimal github-api stub — record calls via file (cmd-substitution is a subshell).
cat > "$TMP/scripts/lib/github-api.sh" <<STUB
gh_latest_tag() {
    echo x >> "$TMP/gh_calls"
    printf 'v9.9.9\n'
}
STUB

# Fake curl: always fails after recording argv (proves no --retry loop).
cat > "$TMP/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MESH_CURL_LOG:?}"
exit 22
CURL
chmod +x "$TMP/bin/curl"

# --- curl flag contract (sourced once) ------------------------------------
# shellcheck source=/dev/null
. "$SCRIPT"

assert "curl flags: no --retry" "yes" \
    "$(printf '%s\n' "${_RB_CURL[*]}" | grep -q -- '--retry' && echo no || echo yes)"
assert "curl flags: has --max-time" "yes" \
    "$(printf '%s\n' "${_RB_CURL[*]}" | grep -q -- '--max-time' && echo yes || echo no)"

# --- in-process breaker (same sourced shell) ------------------------------
: > "$MESH_CURL_LOG"
: > "$TMP/gh_calls"
rm -f "$TMP"/mesh-rust-bins-attempt.*
_RB_TRIED_dust=0
_install_dust >/dev/null 2>"$TMP/dust1.err"; rc1=$?
assert "first dust attempt fails (fake curl)" "1" "$rc1"
assert "first attempt resolved tag once" "1" "$(wc -l < "$TMP/gh_calls" | tr -d ' ')"
assert "first attempt logged download" "yes" \
    "$(grep -q 'downloading dust v9.9.9' "$TMP/dust1.err" && echo yes || echo no)"
assert "first attempt invoked curl once" "1" "$(wc -l < "$MESH_CURL_LOG" | tr -d ' ')"

_install_dust >/dev/null 2>"$TMP/dust2.err"; rc2=$?
assert "second dust attempt circuit-breaks" "1" "$rc2"
assert "circuit breaker message" "yes" \
    "$(grep -qiE 'circuit|loop|already attempted|refusing' "$TMP/dust2.err" && echo yes || echo no)"
assert "second attempt did NOT call gh_latest_tag again" "1" "$(wc -l < "$TMP/gh_calls" | tr -d ' ')"
assert "second attempt did NOT invoke curl again" "1" "$(wc -l < "$MESH_CURL_LOG" | tr -d ' ')"

# --- custom_install-style double re-source (cross-entry TTL stamps) -------
# Engine path: custom_install → `( . "$script"; install )` per entry.
# In-process `_RB_TRIED_*` would reset on a clean entry; TMPDIR attempt stamps
# must keep downloads bounded to 1 per binary per TTL across re-sources.
# Unset parent-shell leftovers so nested subshells match a fresh engine item.
unset _RB_TRIED_dust _RB_TRIED_xh _RB_TRIED_procs
rm -f "$TMP"/mesh-rust-bins-attempt.* "$TMP"/mesh-rust-bins-pending.*
: > "$MESH_CURL_LOG"
: > "$TMP/gh_calls"
rm -f "$HOME/.local/bin/dust" "$HOME/.local/bin/xh" "$HOME/.local/bin/procs"

env -u _RB_TRIED_dust -u _RB_TRIED_xh -u _RB_TRIED_procs bash -c '
    # shellcheck source=/dev/null
    . "$1"
    install
' bash "$SCRIPT" >/dev/null 2>"$TMP/re1.err" || true
curl_after_first="$(wc -l < "$MESH_CURL_LOG" | tr -d ' ')"
gh_after_first="$(wc -l < "$TMP/gh_calls" | tr -d ' ')"
assert "first re-source install: one curl per binary" "3" "$curl_after_first"
assert "first re-source install: one gh tag per binary" "3" "$gh_after_first"

env -u _RB_TRIED_dust -u _RB_TRIED_xh -u _RB_TRIED_procs bash -c '
    # shellcheck source=/dev/null
    . "$1"
    install
' bash "$SCRIPT" >/dev/null 2>"$TMP/re2.err" || true
curl_after_second="$(wc -l < "$MESH_CURL_LOG" | tr -d ' ')"
gh_after_second="$(wc -l < "$TMP/gh_calls" | tr -d ' ')"
assert "second re-source install: no additional curls (TTL stamp)" "$curl_after_first" "$curl_after_second"
assert "second re-source install: no additional gh tags" "$gh_after_first" "$gh_after_second"
assert "second re-source logged circuit breaker" "yes" \
    "$(grep -qiE 'circuit|loop|already attempted|refusing' "$TMP/re2.err" && echo yes || echo no)"

# --- MESH_GH_API_ATTEMPTS non-numeric must not trip set -e ---------------
# Succeeding curl avoids retry/sleep; we only care that digit validation
# prevents `[[ "$max_attempts" -ge 1 ]]` from aborting under set -e.
cat > "$TMP/bin/curl" <<'CURL_OK'
#!/usr/bin/env bash
printf '{}\n'
exit 0
CURL_OK
chmod +x "$TMP/bin/curl"
(
    set -euo pipefail
    export PATH="$TMP/bin:/usr/bin:/bin"
    export MESH_GH_API_ATTEMPTS='not-a-number'
    # shellcheck source=/dev/null
    . "$REAL_GH_API"
    gh_api_curl "https://api.github.com/repos/octocat/Hello-World/releases/latest" >/dev/null
    echo ok
) >"$TMP/gh_api_rc.txt" 2>"$TMP/gh_api.err"
assert "MESH_GH_API_ATTEMPTS non-numeric falls back safely" "ok" \
    "$(tr -d '[:space:]' < "$TMP/gh_api_rc.txt")"

echo ""
echo "rust-bins-fail-fast.test: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
