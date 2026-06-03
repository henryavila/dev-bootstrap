#!/usr/bin/env bash
# Integration test: the engine puts Homebrew's bin on PATH for every item
# subshell, so the package drivers (brew_formula_check runs `brew list`, …) AND
# custom scripts can resolve brew-installed tools (brew, fnm, node, cargo…) by
# BARE name — even when the invoking shell's PATH lacks the (possibly
# non-standard) prefix.
#
# Regression for the node-fnm rc=67: under a /Volumes/External Homebrew prefix
# not on the engine's PATH, node-fnm.sh's `command -v fnm` failed, so install()
# silently no-op'd and the custom verify() reported rc=67 although fnm/node were
# in fact installed. The fix detects $BREW_PREFIX and prepends $BREW_PREFIX/bin.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
ENGINE="$WS/scripts/lib/install-engine.sh"

# macOS + Homebrew only — this is the mac brew-PATH path.
if [[ "$(uname -s)" != "Darwin" ]] || ! bash "$WS/scripts/lib/detect-brew.sh" >/dev/null 2>&1; then
    echo "SKIP engine-brew-path: not macOS or Homebrew not found"
    exit 0
fi

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected [$expected], got [$actual])" >&2; fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TD="$TMP/topics"; mkdir -p "$TD/probe" "$TMP/home" "$TMP/state"

cat > "$TD/probe/manifest.yaml" <<'YAML'
topic:
  label: "Probe"
  order: 10
bundles:
  - name: brewtool
    label: "Brew tool"
    desc: "custom check that resolves a brew tool by bare name"
    items:
      - name: needs-brew
        type: custom
        script: ./needs-brew.sh
YAML

# check() needs `brew` on PATH. brew lives at $BREW_PREFIX/bin/brew, which is NOT
# on the minimal PATH the engine is launched with below — the engine must add it.
# Without the fix: pre-check fails → install (no-op) → verify (check, still
# fails) → rc 67. With the fix: pre-check passes → "already present" → rc 0.
cat > "$TD/probe/needs-brew.sh" <<'SH'
check()   { command -v brew >/dev/null 2>&1; }
install() { :; }
verify()  { check; }
SH

printf 'probe/brewtool\n' > "$TMP/sel.list"

# Launch with a MINIMAL PATH (no Homebrew) — reproduces the broken invocation.
/usr/bin/env -i HOME="$TMP/home" MESH_INSTALL_STATE_DIR="$TMP/state" PATH=/usr/bin:/bin \
    bash "$ENGINE" --topics-dir "$TD" --platform mac \
    --selections "$TMP/sel.list" --non-interactive >/dev/null 2>&1
rc=$?
assert "engine adds brew to PATH → a bare-name custom check passes (no rc=67)" "0" "$rc"

echo
if [[ "$failed" -eq 0 ]]; then echo "engine-brew-path: $passed passed"; exit 0
else echo "engine-brew-path: $failed FAILED, $passed passed" >&2; exit 1; fi
