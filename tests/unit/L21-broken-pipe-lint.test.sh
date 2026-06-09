#!/usr/bin/env bash
# Unit test for lint L21 (no `<fatal-producer> | grep -q` / `| head` in drivers).
# Verifies: (1) the lint passes on the real repo; (2) it flags each fatal producer
# piped to an early-exit consumer; (3) it does NOT flag the safe forms (comments,
# capture-then-test, here-strings, awk-drained pipes, single-line/builtin producers).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
LINT="$WS/scripts/lib/lints/L21-no-broken-pipe-grep-q.sh"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected [$expected], got [$actual])" >&2; fi
}

# Lints are source-only (run via `bash "$lint"`); they must be readable but NOT
# executable (L13 enforces chmod -x under scripts/lib/).
[[ -r "$LINT" ]] || { echo "L21 lint missing/unreadable: $LINT" >&2; exit 1; }
[[ -x "$LINT" ]] && { echo "L21 lint must NOT be executable (L13): $LINT" >&2; exit 1; }

# (1) Real repo must be clean.
bash "$LINT" >/dev/null 2>&1; assert "L21 passes on the real repo" "0" "$?"

# (2)+(3) Planted tree mirroring the repo layout (the lint resolves ROOT from its
# own path, so a copy under $t scans $t/topics).
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/scripts/lib/lints" "$t/topics/x"
cp "$LINT" "$t/scripts/lib/lints/"

cat > "$t/topics/x/bad.sh" <<'SH'
check() {
    fnm list | grep -qE 'v[0-9]'
    launchctl print foo | grep -q running
    "$php_bin" -m | grep -qi sqlsrv
    php8.5 -m | grep -qi mbstring
    cargo --list | head -1
}
SH

cat > "$t/topics/x/good.sh" <<'SH'
check() {
    # comment: fnm list | grep -q must NOT be flagged
    out="$(fnm list)"; [[ "$out" =~ v[0-9] ]]
    grep -qi '^sqlsrv$' <<<"$mods"
    brew services list | awk '{print $2}' | grep -qx started
    dpkg-query -W -f='x' pkg | grep -q installed
    printf '%s' "$x" | grep -qF foo
    fnm list | sed -n 's/v//p' | tail -1
}
SH

out="$(bash "$t/scripts/lib/lints/L21-no-broken-pipe-grep-q.sh" 2>&1)"; rc=$?
assert "flags the bad file (rc=1)" "1" "$rc"

# Every bad line is reported (5 producers).
bad_hits="$(printf '%s\n' "$out" | grep -c 'bad.sh')"
assert "reports all 5 planted violations" "5" "$bad_hits"

# No safe line is reported.
good_hits="$(printf '%s\n' "$out" | grep -c 'good.sh' || true)"
assert "reports zero false positives in good.sh" "0" "$good_hits"

echo
if [[ "$failed" -eq 0 ]]; then echo "L21-broken-pipe-lint: $passed passed"; exit 0
else echo "L21-broken-pipe-lint: $failed FAILED, $passed passed" >&2; exit 1; fi
