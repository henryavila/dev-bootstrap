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

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
. "$VALET"

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
