#!/usr/bin/env bash
# Selective rollback + partial-success contract for rust-bins-wsl.
# Aggregate failure / soft_fail timeout must not wipe siblings that already
# installed successfully in the same attempt.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
SCRIPT="$WS/topics/shell-terminal/wsl/install-rust-bins.sh"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected: [$expected], got: [$actual])" >&2; fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/.local/bin" "$TMP/scripts/lib" "$TMP/artifacts"
export HOME="$TMP/home"
export TMPDIR="$TMP"
export PATH="$TMP/bin:/usr/bin:/bin"
export MESH_WORKSTATION_DIR="$TMP"
export MESH_CURL_LOG="$TMP/curl.log"
export MESH_RUST_BINS_ATTEMPT_TTL=120
: > "$MESH_CURL_LOG"

cat > "$TMP/scripts/lib/github-api.sh" <<STUB
gh_latest_tag() {
    printf 'v9.9.9\n'
}
STUB

# Build minimal fake release archives the real installer expects.
# dust/xh: tar.gz with strip-components=1 (top dir + binary)
# procs: zip with binary at archive root
mkdir -p "$TMP/artifacts/dust-v9.9.9"
echo '#!/bin/sh' > "$TMP/artifacts/dust-v9.9.9/dust"
echo 'echo fake-dust' >> "$TMP/artifacts/dust-v9.9.9/dust"
chmod +x "$TMP/artifacts/dust-v9.9.9/dust"
tar -C "$TMP/artifacts" -czf "$TMP/artifacts/dust.tgz" "dust-v9.9.9"

mkdir -p "$TMP/artifacts/xh-v9.9.9"
echo '#!/bin/sh' > "$TMP/artifacts/xh-v9.9.9/xh"
echo 'echo fake-xh' >> "$TMP/artifacts/xh-v9.9.9/xh"
chmod +x "$TMP/artifacts/xh-v9.9.9/xh"
tar -C "$TMP/artifacts" -czf "$TMP/artifacts/xh.tgz" "xh-v9.9.9"

echo '#!/bin/sh' > "$TMP/artifacts/procs"
echo 'echo fake-procs' >> "$TMP/artifacts/procs"
chmod +x "$TMP/artifacts/procs"
python3 - <<PY
import zipfile
from pathlib import Path
root = Path("$TMP/artifacts")
with zipfile.ZipFile(root / "procs.zip", "w") as zf:
    zf.write(root / "procs", arcname="procs")
PY

# Fake curl: serve dust archive, fail xh/procs (binary1 succeeds, binary2 fails).
cat > "$TMP/bin/curl" <<CURL
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${MESH_CURL_LOG}"
out=""
prev=""
for a in "\$@"; do
    if [[ "\$prev" == "-o" ]]; then out="\$a"; fi
    prev="\$a"
done
url="\${@: -1}"
case "\$url" in
    *dust*)
        cp "$TMP/artifacts/dust.tgz" "\$out" || exit 1
        exit 0
        ;;
    *)
        exit 22
        ;;
esac
CURL
chmod +x "$TMP/bin/curl"

rm -f "$TMP"/mesh-rust-bins-attempt.* "$TMP"/mesh-rust-bins-pending.*
rm -f "$HOME/.local/bin/dust" "$HOME/.local/bin/xh" "$HOME/.local/bin/procs"

# custom_install-style entry (fresh process — no inherited _RB_TRIED_*)
bash -c '
    # shellcheck source=/dev/null
    . "$1"
    install
' bash "$SCRIPT" >/dev/null 2>"$TMP/install.err" || true

assert "dust installed after partial install()" "yes" \
    "$([[ -x "$HOME/.local/bin/dust" ]] && echo yes || echo no)"
assert "xh absent after failed download" "yes" \
    "$([[ -e "$HOME/.local/bin/xh" ]] && echo no || echo yes)"
assert "dust pending stamp cleared on success" "yes" \
    "$([[ -f "$TMP/mesh-rust-bins-pending.dust" ]] && echo no || echo yes)"

# Engine calls custom_rollback on aggregate failure — must leave dust.
bash -c '
    # shellcheck source=/dev/null
    . "$1"
    rollback
' bash "$SCRIPT" >/dev/null 2>"$TMP/rollback.err" || true

assert "rollback leaves successful binary1 (dust)" "yes" \
    "$([[ -x "$HOME/.local/bin/dust" ]] && echo yes || echo no)"

# Incomplete write: pending stamp present → rollback removes that binary only.
echo '#!/bin/sh' > "$HOME/.local/bin/xh"
chmod +x "$HOME/.local/bin/xh"
: > "$TMP/mesh-rust-bins-pending.xh"
bash -c '
    # shellcheck source=/dev/null
    . "$1"
    rollback
' bash "$SCRIPT" >/dev/null 2>/dev/null || true

assert "rollback removes pending incomplete binary2 (xh)" "yes" \
    "$([[ -e "$HOME/.local/bin/xh" ]] && echo no || echo yes)"
assert "rollback still leaves completed dust" "yes" \
    "$([[ -x "$HOME/.local/bin/dust" ]] && echo yes || echo no)"
assert "pending stamp for xh cleared by rollback" "yes" \
    "$([[ -f "$TMP/mesh-rust-bins-pending.xh" ]] && echo no || echo yes)"

echo ""
echo "rust-bins-custom-install-resource.test: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
