#!/usr/bin/env bash
# Unit tests for the mesh pbcopy OSC 52 shim + custom installer.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SHIM="$REPO_ROOT/topics/shell-terminal/bin/pbcopy"
INSTALLER="$REPO_ROOT/topics/shell-terminal/install-pbcopy-osc52.sh"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-pbcopy.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

BIN="$SANDBOX/bin"
mkdir -p "$BIN"
export PATH="$BIN:$PATH"

# Fake system pbcopy: records stdin to a file.
FAKE_PBCOPY="$BIN/real-pbcopy"
FAKE_CLIP="$SANDBOX/clip.txt"
cat > "$FAKE_PBCOPY" <<'EOF'
#!/usr/bin/env bash
cat > "${MESH_PBCOPY_FAKE_CLIP:?}"
EOF
chmod +x "$FAKE_PBCOPY"

export MESH_PBCOPY_REAL="$FAKE_PBCOPY"
export MESH_PBCOPY_FAKE_CLIP="$FAKE_CLIP"

# Load file into variable NAME preserving trailing newlines.
# Usage: load_raw VAR path   — sets $VAR (not via $(...), which strips).
load_raw() {
    local __name="$1" __path="$2" __d
    __d=$(cat "$__path"; printf x) || true
    printf -v "$__name" '%s' "${__d%x}"
}

run_shim() {
    # $1 = HERDR_ENV value or empty to unset; stdin is the clipboard data
    local herdr="${1-}"
    : > "$FAKE_CLIP"
    local sink="$SANDBOX/osc52.out"
    : > "$sink"
    if [[ -n "$herdr" ]]; then
        HERDR_ENV="$herdr" MESH_PBCOPY_OSC52_SINK="$sink" \
            bash "$SHIM" 2>"$SANDBOX/shim.err"
    else
        env -u HERDR_ENV MESH_PBCOPY_OSC52= \
            MESH_PBCOPY_OSC52_SINK="$sink" \
            bash "$SHIM" 2>"$SANDBOX/shim.err"
    fi
}

# ── Source present & marked ──────────────────────────────────────────────────
assert_file_exists "$SHIM" "shim source exists"
assert_true "grep -q mesh-pbcopy-osc52 \"$SHIM\""
pass "shim carries mesh-pbcopy-osc52 marker"
assert_true "grep -q mesh-pbcopy-osc52 \"$INSTALLER\""
pass "installer references marker"

# ── Without herdr: pure passthrough to real pbcopy ───────────────────────────
printf 'plain-copy' | run_shim ""
load_raw got "$FAKE_CLIP"
assert_eq "$got" "plain-copy" "without HERDR_ENV, real pbcopy receives stdin"
load_raw got "$SANDBOX/osc52.out"
assert_eq "$got" "" "without HERDR_ENV, no OSC 52 sink write"

printf 'line\n' | run_shim ""
load_raw got "$FAKE_CLIP"
assert_eq "$got" $'line\n' "preserves trailing newline (passthrough)"

# ── With HERDR_ENV: dual-write ───────────────────────────────────────────────
printf 'remote-copy' | run_shim "1"
load_raw got "$FAKE_CLIP"
assert_eq "$got" "remote-copy" "with HERDR_ENV, real pbcopy still receives stdin"
load_raw osc "$SANDBOX/osc52.out"
assert_contains "$osc" $'\033]52;c;' "with HERDR_ENV, OSC 52 prefix is written"
expected_b64="$(printf '%s' 'remote-copy' | base64 | tr -d '\n\r')"
assert_contains "$osc" "$expected_b64" "with HERDR_ENV, OSC 52 carries base64 payload"
assert_contains "$osc" $'\a' "with HERDR_ENV, OSC 52 ends with BEL"

printf 'a\n\n' | run_shim "1"
load_raw got "$FAKE_CLIP"
assert_eq "$got" $'a\n\n' "dual-write preserves trailing newlines for native"
load_raw osc "$SANDBOX/osc52.out"
expected_b64="$(printf '%s' $'a\n\n' | base64 | tr -d '\n\r')"
assert_contains "$osc" "$expected_b64" "dual-write OSC 52 preserves trailing newlines"

: | run_shim "1"
load_raw got "$FAKE_CLIP"
assert_eq "$got" "" "empty stdin reaches real pbcopy"
load_raw osc "$SANDBOX/osc52.out"
assert_contains "$osc" $'\033]52;c;' "empty stdin still emits OSC 52 frame"

# ── Force flags ──────────────────────────────────────────────────────────────
: > "$FAKE_CLIP"; : > "$SANDBOX/osc52.out"
printf 'force-on' | env -u HERDR_ENV MESH_PBCOPY_OSC52=1 \
    MESH_PBCOPY_REAL="$FAKE_PBCOPY" MESH_PBCOPY_FAKE_CLIP="$FAKE_CLIP" \
    MESH_PBCOPY_OSC52_SINK="$SANDBOX/osc52.out" \
    bash "$SHIM"
load_raw osc "$SANDBOX/osc52.out"
assert_contains "$osc" $'\033]52;c;' "MESH_PBCOPY_OSC52=1 forces OSC 52 outside herdr"
load_raw got "$FAKE_CLIP"
assert_eq "$got" "force-on" "force-on still hits real pbcopy"

: > "$FAKE_CLIP"; : > "$SANDBOX/osc52.out"
printf 'force-off' | HERDR_ENV=1 MESH_PBCOPY_OSC52=0 \
    MESH_PBCOPY_REAL="$FAKE_PBCOPY" MESH_PBCOPY_FAKE_CLIP="$FAKE_CLIP" \
    MESH_PBCOPY_OSC52_SINK="$SANDBOX/osc52.out" \
    bash "$SHIM"
load_raw got "$FAKE_CLIP"
assert_eq "$got" "force-off" "MESH_PBCOPY_OSC52=0 still hits real pbcopy"
load_raw got "$SANDBOX/osc52.out"
assert_eq "$got" "" "MESH_PBCOPY_OSC52=0 disables OSC 52 under herdr"

# ── Oversize payload: native ok, OSC skipped ─────────────────────────────────
: > "$FAKE_CLIP"; : > "$SANDBOX/osc52.out"
big="$(python3 -c 'print("x"*80000, end="")' 2>/dev/null || printf '%*s' 80000 '' | tr ' ' x)"
printf '%s' "$big" | HERDR_ENV=1 MESH_PBCOPY_OSC52_MAX_BYTES=75000 \
    MESH_PBCOPY_REAL="$FAKE_PBCOPY" MESH_PBCOPY_FAKE_CLIP="$FAKE_CLIP" \
    MESH_PBCOPY_OSC52_SINK="$SANDBOX/osc52.out" \
    bash "$SHIM"
assert_eq "$(wc -c < "$FAKE_CLIP" | tr -d ' ')" "80000" "oversize still lands in real pbcopy"
load_raw got "$SANDBOX/osc52.out"
assert_eq "$got" "" "oversize skips OSC 52"

# ── Installer contract (sandbox HOME) ────────────────────────────────────────
export HOME="$SANDBOX/home"
mkdir -p "$HOME"
export MESH_PBCOPY_INSTALL_DIR="$HOME/.local/bin"
INSTALLED="$MESH_PBCOPY_INSTALL_DIR/pbcopy"

# shellcheck disable=SC1090
(
    . "$INSTALLER"
    install
)
assert_file_exists "$INSTALLED" "install() drops ~/.local/bin/pbcopy"
assert_true "grep -q mesh-pbcopy-osc52 \"$INSTALLED\""
pass "installed shim carries marker"
assert_true "test -x \"$INSTALLED\""
pass "installed shim is executable"
assert_true "( . \"$INSTALLER\"; check )"
pass "check() true after install"

# foreign pbcopy refusal
printf '#!/bin/sh\necho foreign\n' > "$INSTALLED"
chmod +x "$INSTALLED"
assert_false "( . \"$INSTALLER\"; install )"
pass "install refuses foreign pbcopy without marker"

# restore ours then uninstall
# shellcheck disable=SC1090
(
    . "$INSTALLER"
    rm -f "$INSTALLED"
    install
    uninstall
)
assert_false "test -e \"$INSTALLED\""
pass "uninstall removes our shim"

# uninstall leaves foreign alone
printf '#!/bin/sh\necho foreign\n' > "$INSTALLED"
# shellcheck disable=SC1090
(
    . "$INSTALLER"
    uninstall
)
assert_true "test -e \"$INSTALLED\""
pass "uninstall does not remove foreign pbcopy"
assert_file_contains "$INSTALLED" "foreign" "foreign content preserved"

# ── Installer functions exist (L09 contract) ─────────────────────────────────
for fn in check install verify repair rollback uninstall; do
    assert_true "grep -Eq '^${fn}\\(\\)' \"$INSTALLER\""
    pass "installer defines ${fn}()"
done

summary
