#!/usr/bin/env bash
# Fail-fast / circuit-breaker contract for WSL rust-bins installer.
# Root cause of CRC hang: nested API+curl retries looked like a resolve/download
# loop on dust; a second attempt at the same binary must refuse immediately.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
SCRIPT="$WS/topics/shell-terminal/wsl/install-rust-bins.sh"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected: [$expected], got: [$actual])" >&2; fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/.local/bin" "$TMP/scripts/lib"
export HOME="$TMP/home"
# Prefer fake curl; keep system bins for mktemp/tar/install but NOT host dust/xh/procs.
export PATH="$TMP/bin:/usr/bin:/bin"
export MESH_WORKSTATION_DIR="$TMP"
export MESH_CURL_LOG="$TMP/curl.log"
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

# Hide host copies if present on PATH elsewhere.
for b in dust xh procs; do
    [[ -x "/usr/bin/$b" || -x "/bin/$b" ]] && continue
    true
done

# shellcheck source=/dev/null
. "$SCRIPT"

assert "curl flags: no --retry" "yes" \
    "$(printf '%s\n' "${_RB_CURL[*]}" | grep -q -- '--retry' && echo no || echo yes)"
assert "curl flags: has --max-time" "yes" \
    "$(printf '%s\n' "${_RB_CURL[*]}" | grep -q -- '--max-time' && echo yes || echo no)"

: > "$MESH_CURL_LOG"
: > "$TMP/gh_calls"
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

# install() must not re-enter dust after circuit break when dust still missing.
: > "$TMP/gh_calls"
: > "$MESH_CURL_LOG"
_RB_TRIED_dust=1
_RB_TRIED_xh=1
_RB_TRIED_procs=1
# Ensure host tools aren't mistaken for installed bins.
command -v dust >/dev/null 2>&1 && assert "precondition: dust absent" "absent" "present"
install >/dev/null 2>"$TMP/inst.err"; irc=$?
assert "install() returns failure when all circuit-broken" "1" "$irc"
assert "install() does not re-resolve after circuit break" "0" "$(wc -l < "$TMP/gh_calls" | tr -d ' ')"

echo ""
echo "rust-bins-fail-fast.test: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
