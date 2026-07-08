#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
LIB="$WS/scripts/lib/mesh-command.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
capture_file="$tmpdir/capture"

passed=0
failed=0

ok() { passed=$((passed + 1)); printf '  ✓ %s\n' "$1"; }
not_ok() { failed=$((failed + 1)); printf '  ✗ %s\n' "$1" >&2; }

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        ok "$name"
    else
        not_ok "$name (expected [$expected], got [$actual])"
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        ok "$name"
    else
        not_ok "$name (missing [$needle])"
    fi
}

assert_file_absent() {
    local name="$1" path="$2"
    if [ ! -e "$path" ]; then
        ok "$name"
    else
        not_ok "$name (unexpected file exists: $path)"
    fi
}

assert_success() {
    local name="$1" rc="$2" out="$3"
    if [ "$rc" -eq 0 ]; then
        ok "$name"
    else
        not_ok "$name (rc=$rc, output=[$out])"
    fi
}

assert_failure_contains() {
    local name="$1" needle="$2" rc="$3" out="$4"
    if [ "$rc" -ne 0 ] && [[ "$out" == *"$needle"* ]]; then
        ok "$name"
    else
        not_ok "$name (rc=$rc, wanted [$needle], output=[$out])"
    fi
}

# shellcheck source=../../scripts/lib/mesh-command.sh
source "$LIB"

cmd_status_main() { :; }
cmd_status_fanout_validate() { :; }
cmd_status_fanout_env() { printf 'NON_INTERACTIVE=1\n'; }
cmd_hidden_main() { :; }
cmd_internal_main() { :; }

register_status() {
    mesh_register_command \
        --name status \
        --summary "Show mesh status" \
        --group core \
        --origin core \
        --visibility public \
        --fanout allowed \
        --handler cmd_status_main \
        --fanout-validator cmd_status_fanout_validate \
        --fanout-env-provider cmd_status_fanout_env
}

capture_command() {
    : > "$capture_file"
    "$@" > "$capture_file" 2>&1
    CAPTURE_RC=$?
    CAPTURE_OUT="$(cat "$capture_file")"
}

mesh_command_reset_registry
capture_command register_status
assert_success "register: complete metadata succeeds" "$CAPTURE_RC" "$CAPTURE_OUT"
assert_eq "names: status registered" "status" "$(mesh_command_names)"
assert_eq "get: summary round-trips" "Show mesh status" "$(mesh_command_get status summary)"
assert_eq "get: group round-trips" "core" "$(mesh_command_get status group)"
assert_eq "get: origin round-trips" "core" "$(mesh_command_get status origin)"
assert_eq "get: visibility round-trips" "public" "$(mesh_command_get status visibility)"
assert_eq "get: fanout round-trips" "allowed" "$(mesh_command_get status fanout)"
assert_eq "get: handler round-trips" "cmd_status_main" "$(mesh_command_get status handler)"
assert_eq "get: fanout validator round-trips" "cmd_status_fanout_validate" "$(mesh_command_get status fanout_validator)"
assert_eq "get: fanout env provider round-trips" "cmd_status_fanout_env" "$(mesh_command_get status fanout_env_provider)"

capture_command register_status
assert_failure_contains "validate: duplicate command fails" "duplicate command: status" "$CAPTURE_RC" "$CAPTURE_OUT"

mesh_command_reset_registry
capture_command mesh_register_command \
    --name missing-summary \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_status_main
assert_failure_contains "validate: missing required field fails" "missing required field: summary" "$CAPTURE_RC" "$CAPTURE_OUT"

capture_command mesh_register_command \
    --name "bad name" \
    --summary "Bad name" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_status_main
assert_failure_contains "validate: bad command name fails" "name is not a valid command name" "$CAPTURE_RC" "$CAPTURE_OUT"

capture_command mesh_register_command \
    --name bad-origin \
    --summary "Bad origin" \
    --group core \
    --origin plugin \
    --visibility public \
    --fanout none \
    --handler cmd_status_main
assert_failure_contains "validate: bad origin enum fails" "origin must be core, legacy, or identity" "$CAPTURE_RC" "$CAPTURE_OUT"

capture_command mesh_register_command \
    --name bad-visibility \
    --summary "Bad visibility" \
    --group core \
    --origin core \
    --visibility private \
    --fanout none \
    --handler cmd_status_main
assert_failure_contains "validate: bad visibility enum fails" "visibility must be public, hidden, or internal" "$CAPTURE_RC" "$CAPTURE_OUT"

capture_command mesh_register_command \
    --name bad-fanout \
    --summary "Bad fanout" \
    --group core \
    --origin core \
    --visibility public \
    --fanout remote \
    --handler cmd_status_main
assert_failure_contains "validate: bad fanout enum fails" "fanout must be allowed or none" "$CAPTURE_RC" "$CAPTURE_OUT"

capture_command mesh_register_command \
    --name missing-handler \
    --summary "Missing handler" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_missing_handler
assert_failure_contains "validate: missing handler function fails" "handler function is not defined: cmd_missing_handler" "$CAPTURE_RC" "$CAPTURE_OUT"

capture_command mesh_register_command \
    --name bad-optional \
    --summary "Bad optional" \
    --group core \
    --origin core \
    --visibility public \
    --fanout allowed \
    --handler cmd_status_main \
    --fanout-validator cmd_missing_validator
assert_failure_contains "validate: invalid optional function fails" "fanout_validator function is not defined: cmd_missing_validator" "$CAPTURE_RC" "$CAPTURE_OUT"

capture_command mesh_register_command \
    --name bad-tab \
    --summary $'Bad\tsummary' \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_status_main
assert_failure_contains "validate: tabs fail" "summary contains a tab or newline" "$CAPTURE_RC" "$CAPTURE_OUT"

capture_command mesh_register_command \
    --name bad-newline \
    --summary $'Bad\nsummary' \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_status_main
assert_failure_contains "validate: newlines fail" "summary contains a tab or newline" "$CAPTURE_RC" "$CAPTURE_OUT"

mesh_command_reset_registry
mesh_register_command \
    --name hidden-cmd \
    --summary "Hidden command" \
    --group zeta \
    --origin core \
    --visibility hidden \
    --fanout none \
    --handler cmd_hidden_main
mesh_register_command \
    --name status \
    --summary "Show mesh status" \
    --group core \
    --origin core \
    --visibility public \
    --fanout allowed \
    --handler cmd_status_main
mesh_register_command \
    --name internal-cmd \
    --summary "Internal command" \
    --group alpha \
    --origin legacy \
    --visibility internal \
    --fanout none \
    --handler cmd_internal_main

public_tsv="$(mesh_command_emit_tsv)"
all_tsv="$(mesh_command_emit_tsv --all)"
internal_tsv="$(mesh_command_emit_tsv --internal)"
assert_eq "tsv: public scope emits public only" $'status\tShow mesh status\tcore\tcore\tpublic\tallowed' "$public_tsv"
assert_contains "tsv: --all includes hidden" $'hidden-cmd\tHidden command\tzeta\tcore\thidden\tnone' "$all_tsv"
assert_contains "tsv: --internal includes internal" $'internal-cmd\tInternal command\talpha\tlegacy\tinternal\tnone' "$internal_tsv"

fixture="$tmpdir/source-pure-module.sh"
side_effect="$tmpdir/side-effect"
cat > "$fixture" <<'EOS'
cmd_fixture_main() { : > "$MESH_TEST_SIDE_EFFECT"; }
mesh_register_command \
    --name fixture \
    --summary "Fixture command" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_fixture_main
EOS

mesh_command_reset_registry
# shellcheck disable=SC1090
MESH_TEST_SIDE_EFFECT="$side_effect" source "$fixture"
assert_eq "source-pure: fixture registered" "fixture" "$(mesh_command_names)"
assert_file_absent "source-pure: handler was not executed while sourcing" "$side_effect"

printf '\nmesh-command-registry: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
