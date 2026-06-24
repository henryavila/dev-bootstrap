#!/usr/bin/env bash
# tests/integration/npx-stdin-detached.test.sh
#
# Regression: the npx driver runs package installers during a NON-INTERACTIVE
# bootstrap (the engine's per-item subshell). If an installer prompts on a TTY,
# the item hangs forever — the live symptom on a fresh `claude-mem` install.
#
# claude-mem v13.8.0 added a "CMEM Online" email prompt + an "Overwrite existing
# installation?" confirm that the spec's --ide/--provider/--runtime/--no-auto-start
# flags do NOT suppress; in install.ts those prompts are gated purely on
# `process.stdin.isTTY`. The driver must therefore feed every npx invocation a
# detached stdin (</dev/null) so isTTY is false and such prompts self-skip.
#
# This pins the contract WITHOUT needing npx/Node/claude-mem present: a fake npx
# records whatever stdin it is handed; with the fix that recording is EMPTY even
# when the caller pipes "interactive" answers in.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
SRC="$WS/scripts/lib/installers/npx.sh"

passed=0; failed=0
ok()  { passed=$((passed+1)); echo "  ✓ $1"; }
bad() { failed=$((failed+1)); echo "  ✗ $1" >&2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# Fake npx on PATH: drains and records whatever stdin it receives — i.e. what an
# interactive installer would read from the keyboard.
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/npx" <<'EOF'
#!/usr/bin/env bash
cat > "$NPX_STDIN_CAPTURE"
exit 0
EOF
chmod +x "$ROOT/bin/npx"

# Drive one verb with a pipe full of "interactive" input; capture what the child
# npx actually saw on stdin. A correctly-detached driver hands it /dev/null, so
# the capture must come back EMPTY despite the upstream pipe.
drive() { # $1=verb  $2=capture-file
    local verb="$1" cap="$2"
    : > "$cap"
    NPX_STDIN_CAPTURE="$cap" PATH="$ROOT/bin:$PATH" bash -c '
        . "'"$SRC"'"
        printf "INTERACTIVE_ANSWER\n" | '"$verb"' "fakepkg install --no-auto-start"
    ' >/dev/null 2>&1 || true
}

# ── behavioural: NO verb may pass caller stdin to the child npx process ──
# install/update run the full installer spec (the live hang); verify/rollback
# run doctor/uninstall — all four are reached from the non-interactive engine,
# so all four must hand the child /dev/null.
for verb in npx_install npx_update npx_verify npx_rollback; do
    drive "$verb" "$ROOT/cap-$verb"
    [[ ! -s "$ROOT/cap-$verb" ]] \
      && ok "$verb detaches stdin (interactive prompt cannot reach the package)" \
      || bad "$verb LEAKED stdin to the package (saw: $(cat "$ROOT/cap-$verb"))"
done

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
