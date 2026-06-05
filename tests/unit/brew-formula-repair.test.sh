#!/usr/bin/env bash
# tests/unit/brew-formula-repair.test.sh
#
# Regression for the reinstall-aware brew-formula driver (verify/operational plan
# §A/§7), fully mocked (fake brew + fake resolver on PATH) so it runs anywhere:
#   - brew_formula_install REINSTALLS when the formula is present (repair path)
#   - brew_formula_install plain-INSTALLS when the formula is absent
#   - brew_formula_repair reinstalls (present)
#   - brew_formula_verify: present + resolver-pass → 0; present + resolver-fail → 1
#   - brew_formula_verify: formula with NO bin/sbin files → presence-only → 0
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
DRIVER="$WS/scripts/lib/installers/brew-formula.sh"

passed=0; failed=0
ok()  { passed=$((passed+1)); echo "  ✓ $1"; }
bad() { failed=$((failed+1)); echo "  ✗ $1" >&2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; LIB="$TMP/lib"; mkdir -p "$BIN" "$LIB"
CALLS="$TMP/brew-calls"

# Fake brew. PRESENT set = formulae listed in $TMP/present (one per line).
# `list --formula -- X`           → rc 0 iff X present
# `list --formula --verbose -- X` → echo fake bin paths from $TMP/bins-<X> if any
# `install`/`reinstall`           → append the verb to $CALLS
# `--prefix`                      → echo $TMP
cat > "$BIN/brew" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "list --formula")
    # forms: list --formula -- X   |   list --formula --verbose -- X
    if [[ "\$3" == "--verbose" ]]; then
      f="\${5:-\$4}"; cat "$TMP/bins-\$f" 2>/dev/null; exit 0
    fi
    f="\${4:-\$3}"; grep -qx "\$f" "$TMP/present" 2>/dev/null; exit \$?
    ;;
esac
case "\$1" in
  install)   echo "install \${@:2}"   >> "$CALLS"; exit 0 ;;
  reinstall) echo "reinstall \${@:2}" >> "$CALLS"; exit 0 ;;
  --prefix)  echo "$TMP"; exit 0 ;;
  outdated)  exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN/brew"

# Fake resolver: pass unless the binary path contains "BROKEN".
cat > "$LIB/mach-o-resolvable.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in *BROKEN*) echo "fake: $1 broken" >&2; exit 1;; *) exit 0;; esac
EOF
chmod +x "$LIB/mach-o-resolvable.sh"

export PATH="$BIN:$PATH"
export BREW_BIN="$BIN/brew"
export MESH_LIB_DIR="$LIB"
# shellcheck disable=SC1090
. "$DRIVER"

# ── reinstall-when-present ──
: > "$CALLS"; printf 'mosh\n' > "$TMP/present"
brew_formula_install mosh >/dev/null 2>&1
if grep -q '^reinstall' "$CALLS" && ! grep -q '^install ' "$CALLS"; then
    ok "brew_formula_install reinstalls a PRESENT formula (repair path)"
else
    bad "present formula should reinstall, not install ($(tr '\n' '|' < "$CALLS"))"
fi

# ── plain-install-when-absent ──
: > "$CALLS"; : > "$TMP/present"   # nothing present
brew_formula_install ripgrep >/dev/null 2>&1
if grep -q '^install ' "$CALLS" && ! grep -q '^reinstall' "$CALLS"; then
    ok "brew_formula_install plain-installs an ABSENT formula"
else
    bad "absent formula should plain-install ($(tr '\n' '|' < "$CALLS"))"
fi

# ── repair() reinstalls ──
: > "$CALLS"; printf 'mosh\n' > "$TMP/present"
brew_formula_repair mosh >/dev/null 2>&1
grep -q '^reinstall' "$CALLS" && ok "brew_formula_repair reinstalls" || bad "repair should reinstall"

# ── verify: present + healthy binary → 0 ──
printf 'mosh\n' > "$TMP/present"
printf '%s/bin/mosh-server\n' "$TMP" > "$TMP/bins-mosh"   # healthy path (no BROKEN)
if brew_formula_verify mosh >/dev/null 2>&1; then ok "verify passes a present formula with resolving binaries"; else bad "verify should pass healthy"; fi

# ── verify: present + broken binary → 1 ──
printf '%s/bin/mosh-server-BROKEN\n' "$TMP" > "$TMP/bins-mosh"
if brew_formula_verify mosh >/dev/null 2>&1; then bad "verify should FAIL when a binary does not resolve"; else ok "verify fails a present formula with an unresolvable binary"; fi

# ── verify: present + NO bin/sbin files → presence-only → 0 ──
printf 'zsh-syntax-highlighting\n' > "$TMP/present"
: > "$TMP/bins-zsh-syntax-highlighting"   # no bin/sbin lines
if brew_formula_verify zsh-syntax-highlighting >/dev/null 2>&1; then ok "verify is presence-only for a no-binary formula"; else bad "no-binary formula should pass presence-only"; fi

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
