#!/usr/bin/env bash
# T-001 — membership: mesh is a schema-admitted bundle scalar, tagged on the
# five membership bundles, parsed as BUNDLE_N_MEMBERSHIP, and accepted by
# validate-manifest --strict. ssh and mosh stay untagged.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

SCHEMA="$WS/schema/manifest.schema.json"
PARSER="$WS/scripts/lib/yaml-parse.sh"
VALIDATOR="$WS/scripts/lib/validate-manifest.sh"

PERSONAL="$WS/topics/personal/manifest.yaml"
IDENTITY="$WS/topics/identity/manifest.yaml"
SYNCTHING="$WS/topics/syncthing/manifest.yaml"
REMOTE="$WS/topics/remote-access/manifest.yaml"

assert_file_exists "$SCHEMA" "schema/manifest.schema.json exists"
assert_file_exists "$PARSER" "scripts/lib/yaml-parse.sh exists"

# Schema: $defs.bundle.properties.membership enum ["mesh"] (additionalProperties
# is false, so the field must be listed or editors/validators reject it).
schema_probe="$(python3 - "$SCHEMA" <<'PY'
import json, sys
schema = json.load(open(sys.argv[1], encoding="utf-8"))
bundle = schema.get("$defs", {}).get("bundle", {})
props = bundle.get("properties", {})
mem = props.get("membership")
if not isinstance(mem, dict):
    print("MISSING")
    sys.exit(0)
enum = mem.get("enum")
typ = mem.get("type")
print("OK" if enum == ["mesh"] and typ == "string" else "BAD:%s:%s" % (typ, enum))
PY
)"
assert_eq "$schema_probe" "OK" 'schema $defs.bundle.properties.membership is string enum [mesh]'

# Parser must admit the key or validate-manifest cannot parse tagged manifests.
# BRE grep: '|' is literal, so this requires membership on the same scalar arm.
assert_file_contains "$PARSER" 'icon_name|membership' \
    "yaml-parse handle_bundle_key admits membership as a bundle scalar"

# Manifests: the five membership bundles declare membership: mesh.
# Do NOT tag remote-access/ssh or remote-access/mosh.
expect_membership() {
    local mf="$1" want_name="$2" label="$3"
    local out rc parsed
    out=$("$PARSER" < "$mf" 2>&1); rc=$?
    if [[ "$rc" -ne 0 ]]; then
        fail "$label: yaml-parse exited $rc"
        printf '      %s\n' "$out" >&2
        return
    fi
    parsed="$(
        eval "$out"
        [[ "${__YAML_PARSE_OK:-0}" == "1" ]] || { echo "NO_SENTINEL"; exit 0; }
        local n="${BUNDLE_COUNT:-0}" i name_v mem_v name mem
        for ((i=0; i<n; i++)); do
            name_v="BUNDLE_${i}_NAME"; mem_v="BUNDLE_${i}_MEMBERSHIP"
            name="${!name_v:-}"; mem="${!mem_v:-}"
            if [[ "$name" == "$want_name" ]]; then
                printf '%s\n' "$mem"
                exit 0
            fi
        done
        echo "MISSING_BUNDLE"
    )"
    assert_eq "$parsed" "mesh" "$label declares membership=mesh (BUNDLE_N_MEMBERSHIP)"
}

expect_no_membership() {
    local mf="$1" want_name="$2" label="$3"
    local out rc parsed
    out=$("$PARSER" < "$mf" 2>&1); rc=$?
    if [[ "$rc" -ne 0 ]]; then
        fail "$label: yaml-parse exited $rc"
        printf '      %s\n' "$out" >&2
        return
    fi
    parsed="$(
        eval "$out"
        [[ "${__YAML_PARSE_OK:-0}" == "1" ]] || { echo "NO_SENTINEL"; exit 0; }
        local n="${BUNDLE_COUNT:-0}" i name_v mem_v name mem
        for ((i=0; i<n; i++)); do
            name_v="BUNDLE_${i}_NAME"; mem_v="BUNDLE_${i}_MEMBERSHIP"
            name="${!name_v:-}"; mem="${!mem_v:-}"
            if [[ "$name" == "$want_name" ]]; then
                printf '%s\n' "${mem:-EMPTY}"
                exit 0
            fi
        done
        echo "MISSING_BUNDLE"
    )"
    assert_eq "$parsed" "EMPTY" "$label is untagged (no BUNDLE_N_MEMBERSHIP)"
}

expect_membership "$PERSONAL"  personal    "personal/personal"
expect_membership "$IDENTITY"  identity    "identity/identity"
expect_membership "$SYNCTHING" syncthing   "syncthing/syncthing"
expect_membership "$REMOTE"    tailscale   "remote-access/tailscale"
expect_membership "$REMOTE"    code-server "remote-access/code-server"
expect_no_membership "$REMOTE" ssh         "remote-access/ssh"
expect_no_membership "$REMOTE" mosh        "remote-access/mosh"

# YAML still carries the literal so schema/editor users see the tag.
assert_file_contains "$PERSONAL"  '^[[:space:]]*membership:[[:space:]]*mesh[[:space:]]*$' \
    "topics/personal/manifest.yaml tags membership: mesh"
assert_file_contains "$IDENTITY"  '^[[:space:]]*membership:[[:space:]]*mesh[[:space:]]*$' \
    "topics/identity/manifest.yaml tags membership: mesh"
assert_file_contains "$SYNCTHING" '^[[:space:]]*membership:[[:space:]]*mesh[[:space:]]*$' \
    "topics/syncthing/manifest.yaml tags membership: mesh"

# validate-manifest --strict must accept the tagged files (parser + §8 rules).
v_out=""
v_rc=0
v_out=$(bash "$VALIDATOR" --strict "$PERSONAL" "$IDENTITY" "$SYNCTHING" "$REMOTE" 2>&1) || v_rc=$?
assert_eq "$v_rc" "0" "validate-manifest --strict exits 0 on tagged membership manifests"
if [[ "$v_rc" -ne 0 ]]; then
    printf '      validator output:\n%s\n' "$v_out" >&2
fi

summary
