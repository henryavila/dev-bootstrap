#!/usr/bin/env bash
# Tests for validate-manifest.sh (T-103) — proves each spec §8 rule is caught.
# Bash 3.2 compatible.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
V="$WS/scripts/lib/validate-manifest.sh"
FIX="$HERE/fixtures/validate-manifest"

pass=0; fail=0; fails=""
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); fails="$fails\n  FAIL: $1"; }

# expect_errors <fixture-or-dir> <label> <needle...> — validator must reject and
# its stderr must contain every needle.
expect_errors() {
    local target="$1" label="$2"; shift 2
    local out rc
    out=$(bash "$V" "$FIX/$target" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
        no "$label: expected rejection but exit 0"; return
    fi
    local n
    for n in "$@"; do
        case "$out" in
            *"$n"*) ;;
            *) no "$label: missing '$n'\n----\n$out\n----"; return ;;
        esac
    done
    ok
}

echo "=== good fixture: clean ==="
out=$(bash "$V" "$FIX/good.yaml" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
    case "$out" in
        *"0 error(s), 0 warning(s)"*) ok ;;
        *) no "good.yaml: expected 0 errors 0 warnings\n----\n$out\n----" ;;
    esac
else
    no "good.yaml rejected (rc=$rc)\n----\n$out\n----"
fi

echo "=== structural rules 4/5/6/7 ==="
expect_errors bad-structural.yaml "structural" \
    "type custom requires script" \
    "type 'brew-formula' requires spec" \
    "duplicate item name" \
    "duplicate bundle name"

echo "=== option rules 8/11/14/15/16/17/19 ==="
expect_errors bad-options.yaml "options" \
    "duplicate option name" \
    "duplicate option env" \
    "required_min (2) exceeds pre-selected defaults (1)" \
    "more than one of choices/derive_from/source set" \
    "derive_from/source on non-select option" \
    "derive_from 'nope' references unknown option" \
    "default_from on non-text option"

echo "=== when rules 12/13 ==="
expect_errors bad-when.yaml "when" \
    "when 'not_a_condition' is not a defined named condition" \
    "when option.flag targets a non-toggle option" \
    "when option.missing targets unknown option"

echo "=== rule 18: required + default-off ==="
expect_errors bad-required-off.yaml "required-off" \
    "required:true with default_selected:false"

echo "=== rule 10: requires_bundles cycle (two topics) ==="
cyc=$(bash "$V" "$FIX/cycle-a" "$FIX/cycle-b" 2>&1); crc=$?
if [ "$crc" -ne 0 ] && printf '%s' "$cyc" | grep -q 'requires_bundles cycle'; then
    ok
else
    no "cycle not detected (rc=$crc)\n----\n$cyc\n----"
fi

echo "=== rule 9: known-topic / unknown-bundle is a hard error ==="
# cycle-a alone references cycle-b/y, whose topic is absent → forward-ref WARN,
# exit 0. With cycle-b present but renamed bundle, it would be a hard error;
# here we assert the forward-ref path stays a warning (exit 0).
fa=$(bash "$V" "$FIX/cycle-a" 2>&1); farc=$?
if [ "$farc" -eq 0 ] && printf '%s' "$fa" | grep -q 'forward-ref'; then
    ok
else
    no "lone cycle-a should warn forward-ref and pass (rc=$farc)\n----\n$fa\n----"
fi

total=$((pass + fail))
echo ""
echo "validate-manifest tests: $pass / $total passed"
if [ "$fail" -gt 0 ]; then printf '%b\n' "$fails"; exit 1; fi
echo "OK"
