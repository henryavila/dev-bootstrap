#!/usr/bin/env bash
# Integration test: the engine puts $HOME/.local/bin on PATH for every item
# subshell, so a custom check()/verify() that resolves a non-brew tool by BARE
# name finds it there — even when the invoking shell's PATH lacks ~/.local/bin
# (early bootstrap, the remote `mesh` wrapper, before shell fragments deploy).
#
# Regression for the custom-script audit RC1 (~/.local/bin cluster): rtk,
# moshi-hook (×2), and the WSL rust bins install to $HOME/.local/bin but verify
# by bare `command -v`. The engine only prepended $BREW_PREFIX/bin (mac), never
# ~/.local/bin, so a correctly-installed tool's post-verify reported rc=67 and
# ABORTED THE WHOLE RUN. The fix prepends $HOME/.local/bin on mac AND wsl.
#
# Unlike engine-brew-path (mac+Homebrew only) this runs on every platform: the
# probe tool lives only in a temp ~/.local/bin and is independent of Homebrew.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
ENGINE="$WS/scripts/lib/install-engine.sh"

# Match the engine's own platform detection so the probe bundle (no platforms:
# restriction) runs and, on mac, the brew block is exercised alongside ours.
if [[ "$(uname -s)" == "Darwin" ]]; then PLAT=mac; else PLAT=wsl; fi

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected [$expected], got [$actual])" >&2; fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TD="$TMP/topics"; mkdir -p "$TD/probe" "$TMP/home/.local/bin" "$TMP/state"

# A correctly-"installed" non-brew tool that lives ONLY in $HOME/.local/bin.
cat > "$TMP/home/.local/bin/faketool" <<'BIN'
#!/usr/bin/env bash
exit 0
BIN
chmod +x "$TMP/home/.local/bin/faketool"

cat > "$TD/probe/manifest.yaml" <<'YAML'
topic:
  label: "Probe"
  order: 10
bundles:
  - name: localbintool
    label: "Local-bin tool"
    desc: "custom check that resolves a ~/.local/bin tool by bare name"
    items:
      - name: needs-localbin
        type: custom
        script: ./needs-localbin.sh
YAML

# check() needs `faketool` on PATH. It lives at $HOME/.local/bin/faketool, which
# is NOT on the minimal PATH the engine is launched with below — the engine must
# add it. Without the fix: pre-check fails → install (no-op) → verify (check,
# still fails) → rc 67. With the fix: pre-check passes → "already present" → rc 0.
cat > "$TD/probe/needs-localbin.sh" <<'SH'
check()   { command -v faketool >/dev/null 2>&1; }
install() { :; }
verify()  { check; }
SH

printf 'probe/localbintool\n' > "$TMP/sel.list"

# Launch with a MINIMAL PATH (no ~/.local/bin) — reproduces the broken invocation.
/usr/bin/env -i HOME="$TMP/home" MESH_INSTALL_STATE_DIR="$TMP/state" PATH=/usr/bin:/bin \
    bash "$ENGINE" --topics-dir "$TD" --platform "$PLAT" \
    --selections "$TMP/sel.list" --non-interactive >/dev/null 2>&1
rc=$?
assert "engine adds ~/.local/bin to PATH → a bare-name custom check passes (no rc=67)" "0" "$rc"

echo
if [[ "$failed" -eq 0 ]]; then echo "engine-localbin-path: $passed passed"; exit 0
else echo "engine-localbin-path: $failed FAILED, $passed passed" >&2; exit 1; fi
