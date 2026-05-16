#!/usr/bin/env bash
# Test harness for P1 YAML parser.
# Bash 3.2 compatible (will run on macOS default bash).
#
# Pass criterion (per spec.md §C17 + handoff §G4 P1):
#   - parser ≤300 LOC
#   - 5/5 valid fixtures pass with expected variable bindings
#   - 3/3 invalid fixtures reject with stderr containing "line N" and "column N"

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
PARSER="$WS/scripts/lib/yaml-parse.sh"
FIXTURES="$HERE/fixtures/yaml-parse"

pass=0
fail=0
fails=""

assert() {
    # assert <label> <condition_eval_string>
    local label="$1"; shift
    if eval "$@"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        fails="$fails\n  FAIL: $label   (cond: $*)"
    fi
}

run_valid() {
    # run_valid <fixture_basename> <inline assertions code>
    local fixture="$1"; shift
    local code="$*"
    local out
    out=$("$PARSER" < "$FIXTURES/$fixture.yaml" 2>&1)
    local rc=$?
    if [ $rc -ne 0 ]; then
        fail=$((fail + 1))
        fails="$fails\n  FAIL: $fixture parser exited $rc, output: $out"
        return
    fi
    # eval in a subshell to isolate var pollution
    if (
        eval "$out"
        eval "$code"
    ); then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        fails="$fails\n  FAIL: $fixture assertions failed (out was: $out)"
    fi
}

run_invalid() {
    # run_invalid <fixture_basename> <expected_substring_in_stderr>
    local fixture="$1"
    local needle="$2"
    local out
    out=$("$PARSER" < "$FIXTURES/$fixture.yaml" 2>&1)
    local rc=$?
    if [ $rc -eq 0 ]; then
        fail=$((fail + 1))
        fails="$fails\n  FAIL: $fixture parser exited 0 but should reject"
        return
    fi
    case "$out" in
        *"$needle"*)
            : pass
            ;;
        *)
            fail=$((fail + 1))
            fails="$fails\n  FAIL: $fixture stderr missing '$needle' (got: $out)"
            return
            ;;
    esac
    # Also require both "line" and "column" markers
    case "$out" in
        *line*[Cc]olumn*|*[Cc]olumn*line*)
            pass=$((pass + 1))
            ;;
        *)
            fail=$((fail + 1))
            fails="$fails\n  FAIL: $fixture stderr missing 'line N column N' marker (got: $out)"
            ;;
    esac
}

# --- Valid fixtures ---

run_valid valid-1-minimal '
    [ "$ITEM_COUNT" = 1 ] || exit 1
    [ "$ITEM_0_NAME" = "ripgrep" ] || exit 1
    [ "$ITEM_0_TYPE" = "brew" ] || exit 1
    [ "$ITEM_0_SPEC" = "ripgrep" ] || exit 1
'

run_valid valid-2-full-fields '
    [ "$ITEM_COUNT" = 1 ] || exit 1
    [ "$ITEM_0_NAME" = "mdprobe" ] || exit 1
    [ "$ITEM_0_TYPE" = "npm-global" ] || exit 1
    [ "$ITEM_0_SPEC" = "@henryavila/mdprobe" ] || exit 1
    [ "$ITEM_0_DESC" = "Markdown review UI" ] || exit 1
    [ "$ITEM_0_CHECK" = "command -v mdprobe" ] || exit 1
    [ "$ITEM_0_POST_COUNT" = 2 ] || exit 1
    [ "$ITEM_0_POST_0" = "mdprobe setup --yes" ] || exit 1
    [ "$ITEM_0_POST_1" = "mdprobe verify" ] || exit 1
    [ "$ITEM_0_REQUIRES_COUNT" = 1 ] || exit 1
    [ "$ITEM_0_REQUIRES_0" = "node" ] || exit 1
    [ "$ITEM_0_PLATFORMS_COUNT" = 2 ] || exit 1
    [ "$ITEM_0_PLATFORMS_0" = "mac" ] || exit 1
    [ "$ITEM_0_PLATFORMS_1" = "linux" ] || exit 1
'

run_valid valid-3-custom-script '
    [ "$ITEM_COUNT" = 1 ] || exit 1
    [ "$ITEM_0_NAME" = "postgres" ] || exit 1
    [ "$ITEM_0_TYPE" = "custom" ] || exit 1
    [ "$ITEM_0_SCRIPT" = "scripts/install-postgres.sh" ] || exit 1
    [ "$ITEM_0_DESC" = "PostgreSQL with launchd wrapper" ] || exit 1
    [ "$ITEM_0_PLATFORMS_COUNT" = 2 ] || exit 1
    [ "$ITEM_0_PLATFORMS_0" = "mac" ] || exit 1
    [ "$ITEM_0_PLATFORMS_1" = "linux" ] || exit 1
'

run_valid valid-4-multiple-items '
    [ "$ITEM_COUNT" = 3 ] || exit 1
    [ "$ITEM_0_NAME" = "node" ] || exit 1
    [ "$ITEM_0_PLATFORMS_COUNT" = 1 ] || exit 1
    [ "$ITEM_0_PLATFORMS_0" = "mac" ] || exit 1
    [ "$ITEM_1_NAME" = "mdprobe" ] || exit 1
    [ "$ITEM_1_TYPE" = "npm-global" ] || exit 1
    [ "$ITEM_1_SPEC" = "@henryavila/mdprobe" ] || exit 1
    [ "$ITEM_1_REQUIRES_COUNT" = 1 ] || exit 1
    [ "$ITEM_1_REQUIRES_0" = "node" ] || exit 1
    [ "$ITEM_2_NAME" = "rtk" ] || exit 1
    [ "$ITEM_2_TYPE" = "custom" ] || exit 1
    [ "$ITEM_2_SCRIPT" = "scripts/install-rtk.sh" ] || exit 1
    [ "$ITEM_2_DESC" = "Token saver" ] || exit 1
'

run_valid valid-5-comments-and-quoting '
    [ "$ITEM_COUNT" = 1 ] || exit 1
    [ "$ITEM_0_NAME" = "gh" ] || exit 1
    [ "$ITEM_0_TYPE" = "brew" ] || exit 1
    [ "$ITEM_0_SPEC" = "gh" ] || exit 1
    [ "$ITEM_0_DESC" = "GitHub CLI" ] || exit 1
    [ "$ITEM_0_POST_COUNT" = 1 ] || exit 1
    [ "$ITEM_0_POST_0" = "gh auth status" ] || exit 1
'

# --- Valid fixture C4 — special chars in values (proves shell_escape works) ---
# Mutation test: if shell_escape is identity-passthrough, the `$` in the value
# would be re-interpreted by `eval` (with set -u: unbound) — fails on assertion.
run_valid valid-6-special-chars '
    [ "$ITEM_COUNT" = 1 ] || exit 1
    [ "$ITEM_0_NAME" = "shell-injection-test" ] || exit 1
    [ "$ITEM_0_SPEC" = "literal-\$HOME-and-\`backticks\`-and-\\backslash" ] || exit 1
    [ "$ITEM_0_DESC" = "double-quoted with \\ backslash and \"escaped\" quote" ] || exit 1
    [ "$ITEM_0_CHECK" = "command -v test-\$HOME-marker" ] || exit 1
    [ "$ITEM_0_POST_COUNT" = 1 ] || exit 1
    [ "$ITEM_0_POST_0" = "echo \$PWD && true" ] || exit 1
'

# --- Valid fixture C3 — tab inside quoted string (was false-positive previously) ---
run_valid valid-7-tab-in-quoted '
    [ "$ITEM_COUNT" = 1 ] || exit 1
    [ "$ITEM_0_NAME" = "tab-in-value" ] || exit 1
    # The DESC value contains literal TAB chars from the YAML; preserved through escape.
    case "$ITEM_0_DESC" in
        *"	"*) ;;
        *) echo "expected TAB in DESC, got: $ITEM_0_DESC" >&2; exit 1 ;;
    esac
'

# --- Invalid fixtures ---

run_invalid invalid-1-tab-indent          "tab"
run_invalid invalid-2-nested-map          "nested"
run_invalid invalid-3-anchor              "anchor"
run_invalid invalid-4-anchor-in-list      "anchor"
run_invalid invalid-5-bracket-in-scalar   "inline list value not allowed"
run_invalid invalid-6-trailing-after-list "trailing content after inline list"
run_invalid invalid-7-partial-emit-then-error "anchor"
# CX-M3 (checkpoint-3): comma inside quoted inline-list value must reject.
run_invalid invalid-8-comma-in-quoted-inline "comma inside quoted values not supported"

# --- C-2 fix (checkpoint-2): __YAML_PARSE_OK=1 sentinel on success ---
# Consumer-side safety: parser must emit the sentinel as the LAST line on
# success so engines can detect partial output (parser failed mid-stream)
# despite command-substitution swallowing exit codes.
echo ""
echo "=== C-2 sentinel emission ==="

# Sentinel present after valid parse.
out_valid=$("$PARSER" < "$FIXTURES/valid-1-minimal.yaml")
if printf '%s' "$out_valid" | tail -1 | grep -q '^__YAML_PARSE_OK=1$'; then
    pass=$((pass+1))
    echo "  PASS: C-2 sentinel emitted as last line on valid parse"
else
    fail=$((fail+1))
    fails="$fails\n  FAIL: C-2 sentinel missing from valid parse output (tail: $(printf '%s' "$out_valid" | tail -1))"
    echo "  FAIL: C-2 sentinel missing from valid parse output"
fi

# Sentinel ABSENT after error parse (partial emit then failure).
out_partial=$("$PARSER" < "$FIXTURES/invalid-7-partial-emit-then-error.yaml" 2>/dev/null)
if printf '%s' "$out_partial" | grep -q '__YAML_PARSE_OK=1'; then
    fail=$((fail+1))
    fails="$fails\n  FAIL: C-2 sentinel WAS emitted on partial-then-error parse (should be absent)"
    echo "  FAIL: C-2 sentinel was emitted on partial-then-error parse (should be absent)"
else
    pass=$((pass+1))
    echo "  PASS: C-2 sentinel ABSENT on partial-then-error parse"
fi

# Spec-mandated consumer pattern works: ok parse → consumer-detect ok.
if (
    set -e
    parsed=$("$PARSER" < "$FIXTURES/valid-1-minimal.yaml") || exit 9
    eval "$parsed"
    [ "${__YAML_PARSE_OK:-0}" = "1" ] || exit 8
    [ "$ITEM_COUNT" = "1" ] || exit 7
    exit 0
); then
    pass=$((pass+1))
    echo "  PASS: C-2 consumer pattern (capture/eval/check-sentinel) succeeds on valid input"
else
    fail=$((fail+1))
    fails="$fails\n  FAIL: C-2 consumer pattern failed on valid input (rc=$?)"
    echo "  FAIL: C-2 consumer pattern failed on valid input"
fi

# Spec-mandated consumer pattern works: partial parse → consumer detects.
# (capture rc → eval partial → assert sentinel absent → die)
if (
    parsed=$("$PARSER" < "$FIXTURES/invalid-7-partial-emit-then-error.yaml" 2>/dev/null)
    parser_rc=$?
    # Parser exited 1, but command-substitution still captured the partial output.
    # Under `eval`, ITEM_0_* gets defined (partial state).
    eval "$parsed" 2>/dev/null || true
    # Sentinel must be absent → consumer rejects partial parse.
    if [ "${__YAML_PARSE_OK:-0}" = "1" ]; then
        exit 7   # consumer would accept partial — BAD
    fi
    # Parser rc should be non-zero too, but the sentinel check is the load-bearing guard.
    [ "$parser_rc" -ne 0 ] || exit 6
    exit 0
); then
    pass=$((pass+1))
    echo "  PASS: C-2 consumer pattern rejects partial parse via missing sentinel"
else
    fail=$((fail+1))
    fails="$fails\n  FAIL: C-2 consumer pattern did NOT reject partial parse (rc=$?)"
    echo "  FAIL: C-2 consumer pattern did NOT reject partial parse"
fi

# --- Mutation test for C-2: remove sentinel emit → consumer pattern should fail-detect ---
echo ""
echo "=== Mutation: remove C-2 sentinel emit → consumer must report missing sentinel ==="
PARSER_BROKEN=$(mktemp -t mesh-p1-parser-broken-XXXXXX.sh)
# Remove the sentinel printf line via python3 (text replacement).
python3 - "$PARSER" "$PARSER_BROKEN" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = "printf '__YAML_PARSE_OK=1\\n'"
if needle not in src:
    print("MUTATION_TARGET_MISSING", file=sys.stderr)
    sys.exit(2)
open(sys.argv[2], "w").write(src.replace(needle, ": # mutation: sentinel removed"))
PY
mutation_rc=$?
chmod +x "$PARSER_BROKEN"
if [ $mutation_rc -ne 0 ]; then
    fail=$((fail+1))
    fails="$fails\n  FAIL: C-2 mutation harness couldn't locate sentinel emit"
    echo "  FAIL: C-2 mutation harness couldn't locate sentinel emit"
else
    # Run broken parser on valid input. Consumer pattern should detect missing sentinel.
    out_mut=$("$PARSER_BROKEN" < "$FIXTURES/valid-1-minimal.yaml")
    if printf '%s' "$out_mut" | grep -q '__YAML_PARSE_OK=1'; then
        fail=$((fail+1))
        fails="$fails\n  FAIL: C-2 mutation didn't remove sentinel (mutation harness broken)"
        echo "  FAIL: C-2 mutation didn't remove sentinel"
    else
        # Consumer pattern with broken parser must reject (no sentinel).
        consumer_rc=0
        (
            parsed=$("$PARSER_BROKEN" < "$FIXTURES/valid-1-minimal.yaml")
            eval "$parsed"
            [ "${__YAML_PARSE_OK:-0}" = "1" ] || exit 1
            exit 0
        ) || consumer_rc=$?
        if [ "$consumer_rc" -ne 0 ]; then
            pass=$((pass+1))
            echo "  PASS: C-2 mutation confirmed sentinel is load-bearing (consumer rejected broken parser)"
        else
            fail=$((fail+1))
            fails="$fails\n  FAIL: C-2 consumer accepted broken parser output without sentinel"
            echo "  FAIL: C-2 consumer accepted broken parser output without sentinel"
        fi
    fi
fi
rm -f "$PARSER_BROKEN"

# --- CX-M1 (checkpoint-3): active mutation harness for shell_escape → identity ---
# Codex audit found this mutation was claimed but no live harness existed in
# p1/test.sh. The valid-6-special-chars fixture catches it implicitly (eval would
# re-interpret $HOME/backticks/etc.), but we now have an explicit harness that
# patches the parser and verifies the fixture assertions break.
echo ""
echo "=== CX-M1 mutation: shell_escape → identity → valid-6 assertions break ==="
PARSER_NOESCAPE=$(mktemp -t mesh-p1-noescape-XXXXXX.sh)
python3 - "$PARSER" "$PARSER_NOESCAPE" <<'PY'
import sys, re
src = open(sys.argv[1]).read()
# Find shell_escape function body and replace with identity passthrough.
start = src.find('shell_escape() {')
if start < 0:
    print("MUTATION_TARGET_MISSING", file=sys.stderr); sys.exit(2)
end = src.find('\n}\n', start)
if end < 0:
    print("MUTATION_END_MISSING", file=sys.stderr); sys.exit(2)
identity = 'shell_escape() {\n    printf %s "$1"\n'
open(sys.argv[2], "w").write(src[:start] + identity + src[end+1:])
PY
mut_noescape_rc=$?
chmod +x "$PARSER_NOESCAPE"
if [ $mut_noescape_rc -ne 0 ]; then
    fail=$((fail+1))
    fails="$fails\n  FAIL: CX-M1 P1 mutation harness couldn't locate shell_escape"
    echo "  FAIL: CX-M1 mutation harness couldn't patch shell_escape"
else
    # With identity shell_escape, `$HOME`/backticks/etc. in the YAML value
    # leak into eval unprotected. The eval either errors or produces a
    # different ITEM_0_SPEC. The original assertion must fail.
    detected_rc=0
    (
        out=$("$PARSER_NOESCAPE" < "$FIXTURES/valid-6-special-chars.yaml" 2>/dev/null)
        eval "$out" 2>/dev/null
        # If the mutation truly took effect, ITEM_0_SPEC should differ from the literal.
        [ "$ITEM_0_SPEC" = 'literal-$HOME-and-`backticks`-and-\backslash' ] || exit 1
        exit 0
    ) >/dev/null 2>&1 || detected_rc=$?
    if [ $detected_rc -ne 0 ]; then
        pass=$((pass+1))
        echo "  PASS: CX-M1 P1 mutation detected (identity shell_escape changes valid-6 output)"
    else
        fail=$((fail+1))
        fails="$fails\n  FAIL: CX-M1 P1 mutation survived — identity escape didn't change valid-6 eval"
        echo "  FAIL: CX-M1 P1 mutation survived — identity escape didn't break valid-6"
    fi
fi
rm -f "$PARSER_NOESCAPE"

# --- Report ---

total=$((pass + fail))
echo ""
echo "P1 parser tests: $pass / $total passed"
if [ $fail -gt 0 ]; then
    printf '%b\n' "$fails"
    exit 1
fi

# Also measure parser LOC
loc=$(grep -cvE '^\s*(#|$)' "$PARSER" 2>/dev/null || echo "?")
total_lines=$(wc -l < "$PARSER" 2>/dev/null || echo "?")
echo "Parser size: $loc non-comment-non-blank LOC ($total_lines total lines)"
if [ "$loc" != "?" ] && [ "$loc" -gt 300 ]; then
    echo "FAIL: parser exceeds 300 LOC cap"
    exit 1
fi
echo "OK"
