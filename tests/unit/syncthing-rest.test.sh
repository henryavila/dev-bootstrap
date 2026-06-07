#!/usr/bin/env bash
# Unit test for the syncthing pairing mechanism (scripts/lib/syncthing-rest.py +
# scripts/lib/syncthing-rest.sh). Covers ONLY the pure, daemon-free surface:
# the YAML-subset reader + schema validation, the fail-closed bind resolver,
# per-node namespacing, the config.xml parsing in the bash lib, and the banner
# renderers. The REST reconcile itself is validated on metal (runtime test),
# like the rest of the engine.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
PY="$WS/scripts/lib/syncthing-rest.py"
LIB="$WS/scripts/lib/syncthing-rest.sh"
export MESH_WORKSTATION_DIR="$WS"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected [$expected], got [$actual])" >&2; fi
}
assert_contains() {
    local name="$1" needle="$2" hay="$3"
    if [[ "$hay" == *"$needle"* ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (missing [$needle])" >&2; fi
}

t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT

# ── fixtures ──
cat > "$t/mesh.yaml" <<'YAML'
# comment
topology: star
introducer: false
gui:
  user: henry
  bind: local
hubs:
  - id: SNGCGN2-CCZSN3Q-LGFO7M4-IE6LHCJ-PMAHTCM-SIQUR3I-OGRCWNT-SFXKHA5
    name: ultron-wsl
    addresses: [dynamic]
admission:
  tier: manual
  allow: []
folders:
  - id: claude-mem-sync
    path: ~/claude-mem-sync
    type: sendreceive
    namespacing: per-node
    stignore: claude/stignore/claude-mem.stignore
YAML

# ── 1. YAML reader + schema defaults ──
out="$(python3 "$PY" read-data "$t/mesh.yaml")"
assert "read-data exits 0" "0" "$?"
get() { printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
assert "topology parsed"        "star"          "$(get 'd["topology"]')"
assert "introducer is bool false" "False"       "$(get 'd["introducer"]')"
assert "gui.user parsed"        "henry"         "$(get 'd["gui"]["user"]')"
assert "gui.bind parsed"        "local"         "$(get 'd["gui"]["bind"]')"
assert "hub name parsed"        "ultron-wsl"    "$(get 'd["hubs"][0]["name"]')"
assert "hub addresses inline-list" "dynamic"    "$(get 'd["hubs"][0]["addresses"][0]')"
assert "admission.tier default" "manual"        "$(get 'd["admission"]["tier"]')"
assert "admission.allow empty"  "0"             "$(get 'len(d["admission"]["allow"])')"
assert "folder type parsed"     "sendreceive"   "$(get 'd["folders"][0]["type"]')"
assert "folder namespacing"     "per-node"      "$(get 'd["folders"][0]["namespacing"]')"

# defaults applied when omitted
printf 'topology: star\nfolders:\n  - id: f\n    path: ~/f\n' > "$t/min.yaml"
out2="$(python3 "$PY" read-data "$t/min.yaml")"
assert "minimal: introducer defaults false" "False" \
    "$(printf '%s' "$out2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["introducer"])')"
assert "minimal: gui.bind defaults local" "local" \
    "$(printf '%s' "$out2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["gui"]["bind"])')"

# ── 2. validation guards ──
printf 'topology: star\nintroducer: true\nhubs:\n  - id: SNGCGN2-CCZSN3Q-LGFO7M4-IE6LHCJ-PMAHTCM-SIQUR3I-OGRCWNT-SFXKHA5\n    name: x\nfolders:\n  - id: f\n    path: ~/f\n' > "$t/bad-intro.yaml"
python3 "$PY" read-data "$t/bad-intro.yaml" >/dev/null 2>&1
assert "introducer:true + star REJECTED (rc3)" "3" "$?"

printf 'topology: mesh\nintroducer: true\nhubs:\n  - id: SNGCGN2-CCZSN3Q-LGFO7M4-IE6LHCJ-PMAHTCM-SIQUR3I-OGRCWNT-SFXKHA5\n    name: x\nfolders:\n  - id: f\n    path: ~/f\n' > "$t/ok-intro.yaml"
python3 "$PY" read-data "$t/ok-intro.yaml" >/dev/null 2>&1
assert "introducer:true + mesh OK (rc0)" "0" "$?"

printf 'topology: star\nhubs:\n  - id: too-short\n    name: x\nfolders:\n  - id: f\n    path: ~/f\n' > "$t/bad-id.yaml"
python3 "$PY" read-data "$t/bad-id.yaml" >/dev/null 2>&1
assert "bad device id REJECTED (rc3)" "3" "$?"

printf 'topology: star\nfolders:\n  - id: f\n' > "$t/no-path.yaml"
python3 "$PY" read-data "$t/no-path.yaml" >/dev/null 2>&1
assert "folder without path REJECTED (rc3)" "3" "$?"

# tabs forbidden for indentation
printf 'gui:\n\tuser: x\n' > "$t/tab.yaml"
python3 "$PY" read-data "$t/tab.yaml" >/dev/null 2>&1
assert "tab indentation REJECTED (rc3)" "3" "$?"

# ── 3. fail-closed bind resolver ──
assert "bind local"       "127.0.0.1:8384" "$(python3 "$PY" resolve-bind local)"
assert "bind explicit ip" "100.71.187.99:8384" "$(python3 "$PY" resolve-bind 100.71.187.99:8384)"
python3 "$PY" resolve-bind 0.0.0.0:8384 >/dev/null 2>&1
assert "bind 0.0.0.0 REJECTED (rc5)" "5" "$?"
assert "bind 0.0.0.0 with override" "0.0.0.0:8384" \
    "$(MESH_SYNCTHING_UNSAFE_BIND=1 python3 "$PY" resolve-bind 0.0.0.0:8384)"
assert "bind local honours --port" "127.0.0.1:9999" "$(python3 "$PY" resolve-bind local --port 9999)"

# ── 4. per-node namespacing ──
assert "namespace-dir = <path>/<myid>" "/tmp/cm/ABC-DEF" \
    "$(python3 "$PY" namespace-dir /tmp/cm ABC-DEF)"

# ── 5. bash lib: config.xml parsing (no daemon) ──
# shellcheck disable=SC1090
. "$LIB"
cat > "$t/config.xml" <<'XML'
<configuration version="37">
    <device id="AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH" name="self">
        <address>dynamic</address>
    </device>
    <gui enabled="true" tls="false">
        <address>0.0.0.0:8384</address>
        <apikey>TESTKEY123abc</apikey>
        <user>henry</user>
    </gui>
</configuration>
XML
assert "st_apikey extracts gui apikey" "TESTKEY123abc" "$(st_apikey "$t/config.xml")"
assert "st_rest_base maps 0.0.0.0→127.0.0.1 (not the device 'dynamic' addr)" \
    "http://127.0.0.1:8384" "$(st_rest_base "$t/config.xml")"

cat > "$t/config-ts.xml" <<'XML'
<configuration><gui enabled="true" tls="true"><address>100.64.0.5:8385</address><apikey>K</apikey></gui></configuration>
XML
assert "st_rest_base honours explicit ip + tls" "https://100.64.0.5:8385" "$(st_rest_base "$t/config-ts.xml")"

# ── 6. banner renderers (branch coverage) ──
hub_json='{"myid":"SNG","self_name":"ultron","am_i_hub":true,"gui":{"user":"henry","url":"http://127.0.0.1:8384","password_action":"kept","password":null},"hubs":[{"id":"SNG","name":"ultron"}],"folders":[{"id":"claude-mem-sync","type":"sendreceive","path":"/h/cm"}],"peers":[],"folder_status":[],"pending_approve":false,"warnings":[]}'
assert_contains "render: hub branch" "this machine is the mesh HUB" "$(printf '%s' "$hub_json" | python3 "$PY" render pair)"

pend_json='{"myid":"4QE","self_name":"mac","am_i_hub":false,"gui":{"user":"henry","url":"http://127.0.0.1:8384","password_action":"created","password":"SECRET123"},"hubs":[{"id":"SNG","name":"ultron"}],"folders":[{"id":"claude-mem-sync","type":"sendreceive","path":"/h/cm"}],"peers":[],"folder_status":[],"pending_approve":true,"warnings":["back it up"]}'
r="$(printf '%s' "$pend_json" | python3 "$PY" render pair)"
assert_contains "render: pending-leaf branch" "join the mesh" "$r"
assert_contains "render: fresh password shown" "SECRET123   ← save this" "$r"
assert_contains "render: warning surfaced" "⚠ back it up" "$r"
# T-003: hub with NO explicit address → fallback hint (no URL to derive)
assert_contains "render: pending fallback hints mesh syncthing url" "on the hub for the address" "$r"

# T-003: hub WITH explicit tcp://IP:port → derived admin URL printed in step 1
pend_addr_json='{"myid":"4QE","self_name":"mac","am_i_hub":false,"gui":{"user":"henry","url":"http://127.0.0.1:8384","password_action":"kept","password":null},"hubs":[{"id":"SNG","name":"ultron","addresses":["tcp://100.71.187.99:22000","dynamic"]}],"folders":[{"id":"claude-mem-sync","type":"sendreceive","path":"/h/cm"}],"peers":[],"folder_status":[],"pending_approve":true,"warnings":[]}'
ra="$(printf '%s' "$pend_addr_json" | python3 "$PY" render pair)"
assert_contains "render: pending shows derived hub admin URL (sync port→8384)" "http://100.71.187.99:8384" "$ra"

paired_json='{"myid":"4QE","self_name":"mac","am_i_hub":false,"gui":{"user":"henry","url":"http://127.0.0.1:8384","password_action":"kept","password":null},"hubs":[{"id":"SNG","name":"ultron"}],"peers":[{"id":"SNG","name":"ultron","connected":true}],"folders":[{"id":"claude-mem-sync","type":"sendreceive","path":"/h/cm"}],"folder_status":[{"id":"claude-mem-sync","state":"idle","globalBytes":1048576,"needBytes":0}],"pending_approve":false,"warnings":[]}'
r="$(printf '%s' "$paired_json" | python3 "$PY" render pair)"
assert_contains "render: paired summary" "mesh status" "$r"
assert_contains "render: kept-password recovery hint" "already set" "$r"

# ── 7. the shipped template scaffold parses ──
python3 "$PY" read-data "$WS/template/sync/syncthing-mesh.yaml.example" >/dev/null 2>&1
assert "shipped template scaffold parses (rc0)" "0" "$?"

# ── 8. topology writer (T-001): the guided star/mesh choice ──
# init-hub's --topology path reuses _set_topology; the `topology` command exercises
# the same writer daemon-free (the REST/prompt wiring is metal-validated).
cp "$WS/template/sync/syncthing-mesh.yaml.example" "$t/topo.yaml"

# set mesh → introducer must become true; the written pair re-parses + validates
out_m="$(python3 "$PY" topology --set mesh --data "$t/topo.yaml")"
assert "topology --set mesh rc0" "0" "$?"
gm() { printf '%s' "$out_m" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
assert "set mesh: reports topology mesh"    "mesh" "$(gm 'd["topology"]')"
assert "set mesh: reports introducer true"  "True" "$(gm 'd["introducer"]')"
rd="$(python3 "$PY" read-data "$t/topo.yaml")"
assert "after set mesh: read-data rc0 (valid pair)" "0" "$?"
gr() { printf '%s' "$rd" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
assert "after set mesh: file topology mesh"   "mesh" "$(gr 'd["topology"]')"
assert "after set mesh: file introducer true" "True" "$(gr 'd["introducer"]')"

# set star → introducer must flip back to false (never leaves the rejected star+true)
python3 "$PY" topology --set star --data "$t/topo.yaml" >/dev/null
assert "topology --set star rc0" "0" "$?"
rd2="$(python3 "$PY" read-data "$t/topo.yaml")"
assert "after set star: read-data rc0 (valid pair)" "0" "$?"
gr2() { printf '%s' "$rd2" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
assert "after set star: file topology star"        "star"  "$(gr2 'd["topology"]')"
assert "after set star: introducer flipped false"  "False" "$(gr2 'd["introducer"]')"
assert "after set star: NO introducer:true left in file" "" \
    "$(grep -E '^introducer:[[:space:]]*true' "$t/topo.yaml" || true)"

# report mode (no --set) returns the current pair, changed=false
out_r="$(python3 "$PY" topology --data "$t/topo.yaml")"
assert "topology report rc0" "0" "$?"
assert "report: topology star" "star" \
    "$(printf '%s' "$out_r" | python3 -c 'import json,sys;print(json.load(sys.stdin)["topology"])')"
assert "report: changed false" "False" \
    "$(printf '%s' "$out_r" | python3 -c 'import json,sys;print(json.load(sys.stdin)["changed"])')"

# invalid topology rejected before any write (usage rc2)
python3 "$PY" topology --set sideways --data "$t/topo.yaml" >/dev/null 2>&1
assert "invalid topology REJECTED (rc2)" "2" "$?"
assert "invalid topology did NOT corrupt the file" "star" \
    "$(python3 "$PY" read-data "$t/topo.yaml" | python3 -c 'import json,sys;print(json.load(sys.stdin)["topology"])')"

# prepend branch: a minimal file missing the introducer line gets a consistent pair
printf 'topology: star\nfolders:\n  - id: f\n    path: ~/f\n' > "$t/topo-min.yaml"
python3 "$PY" topology --set mesh --data "$t/topo-min.yaml" >/dev/null
assert "minimal file: set mesh rc0" "0" "$?"
assert "minimal file: introducer line added true" "True" \
    "$(python3 "$PY" read-data "$t/topo-min.yaml" | python3 -c 'import json,sys;print(json.load(sys.stdin)["introducer"])')"

# ── summary ──
echo
echo "syncthing-rest: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
