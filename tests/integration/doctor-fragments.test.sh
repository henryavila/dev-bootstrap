#!/usr/bin/env bash
# tests/integration/doctor-fragments.test.sh
#
# `mesh doctor` is a health check, not a fragment inventory. Fragment listing is
# opt-in, and backup fragments are hidden unless explicitly requested.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$SELF_DIR/../lib/assert.sh"

DOCTOR="$REPO_ROOT/scripts/runners/doctor.sh"
SANDBOX="$(mktemp -d -t mesh-doctor-fragments.XXXXXX)"
trap '[[ -d "$SANDBOX" ]] && rm -rf "$SANDBOX"' EXIT

HOME_SANDBOX="$SANDBOX/home"
ID="$SANDBOX/identity"
mkdir -p "$HOME_SANDBOX/.bashrc.d" "$HOME_SANDBOX/.zshrc.d" "$ID"
printf '# empty deploy map\n' > "$ID/deploy.map"
printf '# active\n' > "$HOME_SANDBOX/.bashrc.d/30-shell.sh"
printf '# backup\n' > "$HOME_SANDBOX/.bashrc.d/30-shell.sh.bak-20260630"
printf '# active\n' > "$HOME_SANDBOX/.zshrc.d/80-claude-code.sh"
printf '# backup\n' > "$HOME_SANDBOX/.zshrc.d/80-claude-code.sh.bak-20260630"

run_doctor() {
    HOME="$HOME_SANDBOX" \
        MESH_IDENTITY_DIR="$ID" \
        DOCTOR_MARKER_FILES="$SANDBOX/no-marker" \
        DOCTOR_LAUNCHD_DIR="$SANDBOX/no-launchd" \
        EBM_BREW_PREFIX_OVERRIDE="/usr/local" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        NO_COLOR=1 \
        bash "$DOCTOR" "$@"
}

echo "── default doctor output ──"
DEFAULT_OUT="$(run_doctor 2>&1)"
DEFAULT_RC=$?
assert_eq "$DEFAULT_RC" "0" "default doctor exits 0 on clean fixture"
assert_not_contains "$DEFAULT_OUT" "Fragments in" "default doctor does not print fragment inventory"
assert_not_contains "$DEFAULT_OUT" "30-shell.sh" "default doctor output is not polluted by fragment filenames"

echo "── opt-in fragment listing ──"
FRAG_OUT="$(run_doctor --fragments 2>&1)"
assert_contains "$FRAG_OUT" "Fragments in" "--fragments prints fragment sections"
assert_contains "$FRAG_OUT" "30-shell.sh" "--fragments prints active bash fragment"
assert_contains "$FRAG_OUT" "80-claude-code.sh" "--fragments prints active zsh fragment"
assert_not_contains "$FRAG_OUT" ".bak-20260630" "--fragments hides backup fragments by default"
assert_contains "$FRAG_OUT" "1 backup fragment(s) hidden" "--fragments summarizes hidden backups"

echo "── full fragment inventory ──"
ALL_OUT="$(run_doctor --fragments --all-fragments 2>&1)"
assert_contains "$ALL_OUT" "30-shell.sh.bak-20260630" "--all-fragments includes backup bash fragments"
assert_contains "$ALL_OUT" "80-claude-code.sh.bak-20260630" "--all-fragments includes backup zsh fragments"

summary
