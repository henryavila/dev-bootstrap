#!/usr/bin/env bash
# tests/integration/atuin-rc-isolation.test.sh
#
# install-atuin.sh wraps the official atuin setup script (which unconditionally
# appends `eval "$(atuin init …)"` to ~/.zshrc and ~/.bashrc, with no opt-out) in
# a snapshot/restore so it never leaves the mesh-managed rc files dirty — that
# dirtying is what the deploy overwrite-guard refuses, silently blocking the
# canonical rc deploy on a fresh machine (it broke the CI smoke test). This pins
# the restore contract for `_atuin_restore_rc` with pure file ops (no network):
#   - a file that EXISTED before atuin is byte-restored (atuin's append dropped)
#   - a file atuin CREATED from nothing is removed (so mesh deploys the marked one)
# Sourcing install-atuin.sh only DEFINES functions (no top-level side effects).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
SCRIPT="$WS/topics/shell-terminal/wsl/install-atuin.sh"

passed=0; failed=0
ok()  { passed=$((passed+1)); echo "  ✓ $1"; }
bad() { failed=$((failed+1)); echo "  ✗ $1" >&2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# shellcheck source=/dev/null
. "$SCRIPT"

declare -f _atuin_restore_rc >/dev/null \
  && ok "install-atuin.sh defines _atuin_restore_rc" || bad "no _atuin_restore_rc helper"
grep -q "snapshot" "$SCRIPT" && grep -q "_atuin_restore_rc" "$SCRIPT" \
  && ok "install() wraps the installer in a snapshot/restore" || bad "install() lacks the snapshot/restore wrap"

# ── 1. pre-existing file: append reverted, byte-identical to the original ──
rc="$ROOT/.bashrc"
printf '# skel bashrc\nexport PS1="$ "\n' > "$rc"
bak="$(mktemp)"; cp -p "$rc" "$bak"                 # snapshot taken before atuin
orig_sum="$(cksum < "$rc")"
printf '\n[[ -f ~/.bash-preexec.sh ]] && source ~/.bash-preexec.sh\neval "$(atuin init bash)"\n' >> "$rc"  # atuin appends
[[ "$(cksum < "$rc")" != "$orig_sum" ]] || bad "test setup: append did not change the file"
_atuin_restore_rc "$rc" "$bak"
[[ -f "$rc" ]]                          && ok "pre-existing rc file is kept"                  || bad "pre-existing rc file was removed"
[[ "$(cksum < "$rc")" == "$orig_sum" ]] && ok "pre-existing rc file restored byte-identical (atuin append reverted)" || bad "rc file not restored to its original bytes"
! grep -q "atuin init bash" "$rc"      && ok "atuin's init line no longer present in the restored file" || bad "atuin init line survived the restore"
[[ ! -e "$bak" ]]                       && ok "the snapshot temp file is cleaned up"          || bad "snapshot temp not removed"

# ── 2. file atuin CREATED from nothing: removed so mesh deploys the marked one ──
zrc="$ROOT/.zshrc"                       # did NOT exist before atuin → empty backup path
printf '\neval "$(atuin init zsh)"\n' > "$zrc"   # atuin creates it
_atuin_restore_rc "$zrc" ""
[[ ! -e "$zrc" ]] && ok "an atuin-created rc file is removed (empty backup path)" || bad "atuin-created rc file was not removed"

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
