#!/usr/bin/env bash
# tests/integration/topic-45-docker.test.sh — containers/docker v2 contract.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
TOPIC="$REPO_ROOT/topics/containers"
ENGINE="$REPO_ROOT/scripts/lib/install-engine.sh"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

echo "Test 1: containers/docker structure"
assert_file_exists "$TOPIC/manifest.yaml" "manifest.yaml present"
assert_file_exists "$TOPIC/post-setup-wsl.sh" "post-setup-wsl.sh present"
assert_false "test -e '$TOPIC/install.mac.sh'" "legacy install.mac.sh is gone"
assert_false "test -e '$TOPIC/install.wsl.sh'" "legacy install.wsl.sh is gone"

echo
echo "Test 2: post-setup-wsl.sh custom contract"
for fn in check install verify rollback; do
    ASSERT_MSG="post-setup-wsl.sh defines $fn()" \
        assert_true "grep -qE '^${fn}\\(\\)' '$TOPIC/post-setup-wsl.sh'"
done

echo
echo "Test 3: engine closure"
closure_mac="$(bash "$ENGINE" --topics-dir "$REPO_ROOT/topics" --platform mac \
    --bundle containers/docker --print-closure 2>/dev/null)"
closure_wsl="$(bash "$ENGINE" --topics-dir "$REPO_ROOT/topics" --platform wsl \
    --bundle containers/docker --print-closure 2>/dev/null)"
assert_contains "$closure_mac" "containers/docker" "mac closure includes containers/docker"
assert_contains "$closure_wsl" "containers/docker" "wsl closure includes containers/docker"

summary
