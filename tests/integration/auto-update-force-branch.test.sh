#!/usr/bin/env bash
# Integration test for `mesh update --force` (auto-update.sh).
#
# The branch gate normally restricts updates to `main`, so the shell-start
# auto-update never pulls a feature branch you're actively working on. --force
# bypasses that gate for an EXPLICIT update of the CURRENT branch — used by a
# fleet running a release/feature branch and by `mesh setup`. (The clean-tree
# and unpushed-commit guards are unaffected; --force only overrides the branch.)
#
# Uses real local git repos (bare remote + clone behind upstream); no network.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
AU="$REPO_ROOT/scripts/runners/auto-update.sh"
# shellcheck source=../lib/assert.sh
source "$SELF_DIR/../lib/assert.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# bare remote + a clone on a feature branch; install.sh-only → identity-type repo
git init -q --bare "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/work" 2>/dev/null
(
    cd "$TMP/work" || exit 1
    printf '#!/usr/bin/env bash\nexit 0\n' > install.sh
    git add install.sh; git commit -qm init; git branch -M main; git push -q origin main
    git checkout -q -b feat; git push -q -u origin feat
) 2>/dev/null
OLD="$(git -C "$TMP/work" rev-parse HEAD)"

# advance origin/feat by one commit from a second clone (so `work` is behind)
git clone -q "$TMP/remote.git" "$TMP/pusher" 2>/dev/null
(
    cd "$TMP/pusher" || exit 1
    git checkout -q feat; echo x > new.txt; git add new.txt
    git commit -qm "remote ahead"; git push -q origin feat
) 2>/dev/null
NEW="$(git -C "$TMP/pusher" rev-parse feat)"

cat > "$TMP/conf" <<EOF
AUTO_UPDATE_REPOS=("$TMP/work")
: "\${AUTO_UPDATE_FETCH_TIMEOUT:=5}"
: "\${AUTO_UPDATE_SUDO_REGEX:=NOMATCHXYZ}"
EOF

run_au() { local sd="$1"; shift; AUTO_UPDATE_CONF="$TMP/conf" AUTO_UPDATE_STATE_DIR="$sd" bash "$AU" "$@" 2>&1; }

# ── without --force: a non-main branch is skipped (gate), HEAD unchanged ──
# Pre-seed last-applied (= a machine that has updated before, not a first run).
mkdir -p "$TMP/st1"; printf '%s\n' "$OLD" > "$TMP/st1/last-applied-work"
out_skip="$(run_au "$TMP/st1")"
assert_contains "$out_skip" "pulado: work em branch feat" "non-main branch skipped without --force"
assert_contains "$out_skip" "use --force" "skip message hints at --force"
assert_eq "$(git -C "$TMP/work" rev-parse HEAD)" "$OLD" "HEAD unchanged without --force"

# ── with --force: the feature branch is pulled to origin/feat ──
mkdir -p "$TMP/st2"; printf '%s\n' "$OLD" > "$TMP/st2/last-applied-work"
out_force="$(run_au "$TMP/st2" --force)"
assert_contains "$out_force" "forçando update de work na branch feat" "--force overrides the branch gate"
assert_eq "$(git -C "$TMP/work" rev-parse HEAD)" "$NEW" "HEAD advanced to origin/feat with --force"

summary
