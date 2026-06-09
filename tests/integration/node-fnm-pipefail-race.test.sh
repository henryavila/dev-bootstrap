#!/usr/bin/env bash
# Integration test: node-fnm.sh detects an installed Node version WITHOUT a
# `fnm list | grep -q` pipeline, so it is immune to the broken-pipe race that
# made the engine's pre-check intermittently report "no Node version present".
#
# Regression for the node-fnm rc=1 flake (~50% on metal): the engine runs
# drivers under `set -o pipefail`. `fnm list | grep -qE …` lets grep -q close the
# pipe on the first match; `fnm` is Rust (ignores SIGPIPE) so its next write hits
# EPIPE and it PANICS (exit 101); pipefail then adopts the 101 even though grep
# matched → false negative. The fix captures the output and tests it with bash
# `[[ =~ ]]` (no pipe, no early reader, no race).
#
# This test uses a STUB `fnm` that faithfully reproduces the failure mode: it
# ignores SIGPIPE and exits 101 the moment a write fails (EPIPE), and sleeps
# between lines so a `grep -q` reader reliably closes the pipe first. Under that
# stub the OLD pattern fails deterministically and the SHIPPED helper passes
# deterministically — so the test has teeth (proven RED for the antipattern,
# GREEN for the fix) and does not depend on real timing.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
DRIVER="$WS/topics/languages/node-fnm.sh"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected [$expected], got [$actual])" >&2; fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/bin"; mkdir -p "$STUB"

# Adversarial fnm stub: a SIGPIPE-ignoring producer that exits 101 on EPIPE
# (exactly like the real Rust binary) and lingers between lines so any early
# reader close is observed on the NEXT write.
cat > "$STUB/fnm" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    trap '' PIPE            # mimic Rust: SIGPIPE ignored → writes return EPIPE
    for line in "* v22.22.3" "* v24.15.0 default" "* v24.16.0 lts-latest" "* system"; do
      sleep 0.02
      echo "$line" || exit 101   # EPIPE on a closed pipe → panic-equivalent rc
    done
    ;;
  env)     echo 'export FNM_DIR="$HOME/.fnm"' ;;
  *)       : ;;
esac
SH
chmod +x "$STUB/fnm"
export PATH="$STUB:/usr/bin:/bin"
export HOME="$TMP/home"; mkdir -p "$HOME"

N=12

# ── RED: the OLD antipattern must fail under the stub (proves the harness bites)
old_fail=0
for ((i=0; i<N; i++)); do
    ( set -o pipefail; fnm list 2>/dev/null | grep -qE 'v[0-9]+\.[0-9]+\.[0-9]+' ) || old_fail=$((old_fail+1))
done
# Expect the old pipeline to fail every iteration (grep -q closes → stub exits 101).
if (( old_fail == N )); then
    assert "OLD 'fnm list | grep -q' is broken under the adversarial stub" "RED" "RED"
else
    assert "OLD 'fnm list | grep -q' is broken under the adversarial stub" "RED" "only $old_fail/$N failed — harness not reproducing the race"
fi

# ── GREEN: the SHIPPED helper must pass every iteration under the same stub.
# Source the real driver and exercise its real _fnm_has_node + check().
# shellcheck disable=SC1090
. "$DRIVER"

helper_fail=0
for ((i=0; i<N; i++)); do
    ( set -euo pipefail; _fnm_has_node ) || helper_fail=$((helper_fail+1))
done
assert "_fnm_has_node passes deterministically under pipefail (no broken-pipe race)" "0" "$helper_fail"

check_fail=0
for ((i=0; i<N; i++)); do
    ( set -euo pipefail; check ) || check_fail=$((check_fail+1))
done
assert "check() passes deterministically under pipefail (no broken-pipe race)" "0" "$check_fail"

# ── Negative case: with NO real version line, _fnm_has_node must return non-zero.
cat > "$STUB/fnm" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list) trap '' PIPE; echo "* system" ;;
  env)  echo 'export FNM_DIR="$HOME/.fnm"' ;;
  *)    : ;;
esac
SH
chmod +x "$STUB/fnm"
( set -euo pipefail; _fnm_has_node ); neg_rc=$?
assert "_fnm_has_node returns non-zero when only '* system' is present" "1" "$neg_rc"

# ── Static guard: the shipped driver must not reintroduce a `fnm list | grep -q`
# in CODE (comments that warn about it are fine — hence strip comment lines).
# Tested with a pipe-free bash `[[ =~ ]]` (the very fix this guards) so the guard
# can't itself flake: `.` doesn't cross newlines, so it only matches within a
# single code line.
code_only="$(grep -vE '^[[:space:]]*#' "$DRIVER")"
if [[ "$code_only" =~ fnm[[:space:]]+list.*\|.*grep[[:space:]]+-[a-zA-Z]*q ]]; then
    assert "driver code contains no 'fnm list | grep -q' antipattern" "absent" "present"
else
    assert "driver code contains no 'fnm list | grep -q' antipattern" "absent" "absent"
fi

echo
if [[ "$failed" -eq 0 ]]; then echo "node-fnm-pipefail-race: $passed passed"; exit 0
else echo "node-fnm-pipefail-race: $failed FAILED, $passed passed" >&2; exit 1; fi
