#!/usr/bin/env bash
# tests/unit/valet-stack-probe.test.sh
#
# Regression for the valet operational hardening (verify/operational plan §B/§7):
#   - _valet_external_unmounted: external+unmounted → defer; external+mounted and
#     non-external → proceed (fake `mount`)
#   - _valet_stack_ok detects a down/absent serving stack
#   - install() DEFERS on an unmounted /Volumes/* CODE_DIR — no `valet install`,
#     no phantom dir created (the §C/D-3 no-repair-on-unmounted-volume guard)
# valet.sh is a mac topic script but sources cleanly anywhere (function defs only).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
VALET="$WS/topics/web/mac/valet.sh"

passed=0; failed=0
ok()  { passed=$((passed+1)); echo "  ✓ $1"; }
bad() { failed=$((failed+1)); echo "  ✗ $1" >&2; }

TMP="$(mktemp -d)"
SOCKET_FIXTURE_PID=""
cleanup() {
    if [[ -n "$SOCKET_FIXTURE_PID" ]]; then
        kill "$SOCKET_FIXTURE_PID" 2>/dev/null || true
        wait "$SOCKET_FIXTURE_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

# shellcheck disable=SC1090
. "$VALET"

# ── php-fpm AF_UNIX socket must be a live listener, not merely a path ──
SOCKET_DIR="$TMP/sockets"
mkdir -p "$SOCKET_DIR"
REGULAR_SOCKET="$SOCKET_DIR/regular.sock"
BROKEN_SOCKET="$SOCKET_DIR/broken.sock"
BOUND_SOCKET="$SOCKET_DIR/bound.sock"
LISTEN_SOCKET="$SOCKET_DIR/listen.sock"
: > "$REGULAR_SOCKET"
ln -s "$SOCKET_DIR/missing.sock" "$BROKEN_SOCKET"

python3 - "$BOUND_SOCKET" "$LISTEN_SOCKET" "$SOCKET_DIR/ready" <<'PY' &
import os
import socket
import sys
import time

bound_path, listen_path, ready_path = sys.argv[1:]
for path in (bound_path, listen_path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass

bound = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
bound.bind(bound_path)

listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(listen_path)
listener.listen(1)

with open(ready_path, "w", encoding="utf-8") as handle:
    handle.write("ready\n")

connection, _ = listener.accept()
connection.close()
while True:
    time.sleep(1)
PY
SOCKET_FIXTURE_PID=$!

for ((n=1; n<=50; n++)); do
    [[ -s "$SOCKET_DIR/ready" ]] && break
    sleep 0.02
done

if ! declare -F _valet_unix_socket_accepting >/dev/null 2>&1; then
    bad "valet defines an AF_UNIX accepting-socket probe"
else
    if _valet_unix_socket_accepting "$REGULAR_SOCKET"; then
        bad "regular file must not satisfy the php-fpm socket probe"
    else
        ok "regular file does not satisfy the php-fpm socket probe"
    fi
    if _valet_unix_socket_accepting "$BROKEN_SOCKET"; then
        bad "broken symlink must not satisfy the php-fpm socket probe"
    else
        ok "broken symlink does not satisfy the php-fpm socket probe"
    fi
    if _valet_unix_socket_accepting "$BOUND_SOCKET"; then
        bad "bound-but-not-listening AF_UNIX socket must fail the probe"
    else
        ok "bound-but-not-listening AF_UNIX socket fails the probe"
    fi
    if _valet_unix_socket_accepting "$LISTEN_SOCKET"; then
        ok "listening AF_UNIX socket accepts the probe"
    else
        bad "listening AF_UNIX socket should accept the probe"
    fi
fi

if declare -f _valet_stack_ok 2>/dev/null | grep -q '_valet_unix_socket_accepting'; then
    ok "_valet_stack_ok uses the accepting-socket probe"
else
    bad "_valet_stack_ok must use the accepting-socket probe"
fi

# Deterministic `mount`: only /Volumes/RealVol is mounted.
mount() { printf '/dev/disk3s1 on /Volumes/RealVol (apfs, local, nodev)\n'; }

# ── _valet_external_unmounted ──
CODE_DIR="$HOME/code/web";        _valet_external_unmounted && r=0 || r=1; [[ "$r" -eq 1 ]] && ok "non-external CODE_DIR → not deferred" || bad "non-external should not defer"
CODE_DIR="/Volumes/RealVol/code"; _valet_external_unmounted && r=0 || r=1; [[ "$r" -eq 1 ]] && ok "external + MOUNTED → not deferred" || bad "mounted external should not defer"
CODE_DIR="/Volumes/Bogus/code";   _valet_external_unmounted && r=0 || r=1; [[ "$r" -eq 0 ]] && ok "external + UNMOUNTED → defer" || bad "unmounted external should defer"

# ── _valet_stack_ok detects a down stack (normal test/CI state) ──
if _valet_stack_ok 2>/dev/null; then
    echo "  • valet stack is fully serving on this host — skipping dead-stack assertion"
else
    ok "_valet_stack_ok detects a down/absent serving stack"
fi

# ── install() defers on an unmounted external volume (no valet install, no phantom) ──
FAKEBIN="$TMP/fb"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/composer" <<EOF
#!/usr/bin/env bash
[[ "\$*" == *"bin-dir"* ]] && echo "$FAKEBIN"
exit 0
EOF
cat > "$FAKEBIN/valet" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$TMP/valet-calls"
[[ "\$1" == "--version" ]] && echo "Laravel Valet 4.x"
exit 0
EOF
chmod +x "$FAKEBIN/composer" "$FAKEBIN/valet"

PHANTOM="/Volumes/Bogus_$$"
(
    export PATH="$FAKEBIN:$PATH"
    export CODE_DIR="$PHANTOM/code"
    # mount() defined above is in scope; ensure Bogus_$$ is reported unmounted.
    mount() { printf '/dev/disk3s1 on /Volumes/RealVol (apfs)\n'; }
    install >/dev/null 2>&1
)
rc=$?
no_install=1; [[ -f "$TMP/valet-calls" ]] && grep -q '^install' "$TMP/valet-calls" && no_install=0
[[ "$rc" -eq 0 && "$no_install" -eq 1 && ! -e "$PHANTOM" ]] \
    && ok "install() defers on unmounted /Volumes/* (rc 0, no \`valet install\`, no phantom dir)" \
    || bad "install() did not cleanly defer (rc=$rc, valet-install-called=$((1-no_install)), phantom=$([[ -e "$PHANTOM" ]] && echo yes || echo no))"

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
