#!/usr/bin/env bash
# tests/unit/mach-o-resolvable.test.sh
#
# Regression for scripts/lib/mach-o-resolvable.sh (verify/operational plan §A/§7):
#   - detects a missing ABSOLUTE dylib (the live mosh class) → rc 1
#   - passes a healthy binary → rc 0
#   - resolves @rpath/@loader_path deps that exist → rc 0
#   - non-Mach-O file (script) → rc 0 (nothing to disprove)
#   - absent binary → rc 1
#   - /usr/lib + /System deps (dyld shared cache, not on disk) → rc 0
#
# macOS-only (otool/install_name_tool/Mach-O). Skips cleanly elsewhere. The broken
# fixture is SYNTHESIZED with install_name_tool so the test stays valid after the
# live mosh is repaired.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
R="$WS/scripts/lib/mach-o-resolvable.sh"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "  • skipped (not macOS — Mach-O probe is mac-only)"
    echo "Results: 0 passed, 0 failed (skipped)"
    exit 0
fi
if ! command -v otool >/dev/null 2>&1; then
    echo "  • skipped (otool not available)"
    echo "Results: 0 passed, 0 failed (skipped)"
    exit 0
fi

passed=0; failed=0
ok()  { passed=$((passed+1)); echo "  ✓ $1"; }
bad() { failed=$((failed+1)); echo "  ✗ $1" >&2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# healthy system binary (deps all in /usr/lib shared cache) → pass
if bash "$R" /bin/ls >/dev/null 2>&1; then ok "/bin/ls (system, /usr/lib deps) resolves"; else bad "/bin/ls should resolve"; fi

# absent binary → fail
if bash "$R" "$TMP/does-not-exist" >/dev/null 2>&1; then bad "absent binary should fail"; else ok "absent binary → rc 1"; fi

# non-Mach-O (shell script) → pass (nothing to disprove)
printf '#!/bin/sh\necho hi\n' > "$TMP/script.sh"; chmod +x "$TMP/script.sh"
if bash "$R" "$TMP/script.sh" >/dev/null 2>&1; then ok "non-Mach-O script → rc 0"; else bad "non-Mach-O script should pass"; fi

# healthy copy of a Mach-O binary → pass; broken copy (dep rewritten to a bogus
# absolute path via install_name_tool) → fail.
if command -v install_name_tool >/dev/null 2>&1; then
    cp /bin/ls "$TMP/healthy"; chmod u+w "$TMP/healthy"
    if bash "$R" "$TMP/healthy" >/dev/null 2>&1; then ok "healthy Mach-O copy resolves"; else bad "healthy copy should resolve"; fi

    cp /bin/ls "$TMP/broken"; chmod u+w "$TMP/broken"
    # Pick an existing absolute dep and rewrite it to a guaranteed-missing path.
    # The replacement must be SHORTER than the original so the load command still
    # fits (arm64 install_name_tool refuses to grow a load command), and absolute
    # + non-/usr/lib so the resolver concretely disproves it. `/zz/m.dylib` (11
    # chars) is shorter than any real /usr/lib dep and never exists.
    dep="$(otool -L "$TMP/broken" 2>/dev/null | awk 'NR>1 && !/:$/ {print $1; exit}')"
    if [[ -n "$dep" ]] && install_name_tool -change "$dep" "/zz/m.dylib" "$TMP/broken" 2>/dev/null; then
        if bash "$R" "$TMP/broken" >/dev/null 2>&1; then
            bad "broken Mach-O (missing absolute dylib) should FAIL"
        else
            ok "broken Mach-O (rewritten dep → missing absolute dylib) → rc 1"
        fi
    else
        echo "  • install_name_tool rewrite unavailable — skipping broken-dylib case"
    fi
else
    echo "  • install_name_tool not available — skipping healthy/broken copy cases"
fi

# @rpath/@loader_path resolution: probe any installed binary that uses @rpath and
# resolves today; it MUST pass (false-fail here aborts real brew installs).
rpath_bin=""
for cand in /Volumes/External/homebrew/Cellar/*/*/bin/* /opt/homebrew/Cellar/*/*/bin/* /usr/local/Cellar/*/*/bin/*; do
    [[ -f "$cand" && -x "$cand" ]] || continue
    if otool -L "$cand" 2>/dev/null | awk 'NR>1 && !/:$/ {print $1}' | grep -q '^@rpath'; then
        rpath_bin="$cand"; break
    fi
done
if [[ -n "$rpath_bin" ]]; then
    if bash "$R" "$rpath_bin" >/dev/null 2>&1; then
        ok "@rpath binary resolves ($(basename "$rpath_bin"))"
    else
        bad "@rpath binary should resolve but failed: $rpath_bin"
    fi
else
    echo "  • no @rpath binary found to probe — skipping @rpath case"
fi

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
