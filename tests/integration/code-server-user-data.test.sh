#!/usr/bin/env bash
# tests/integration/code-server-user-data.test.sh
#
# Regression coverage for code-server's persistent VS Code user-data dir. The
# GitHub Authentication provider stores OAuth sessions through VS Code
# SecretStorage and extension state under the user data tree; config/plist/binary
# alone are not enough to declare the install healthy.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
DRIVER="$REPO_ROOT/topics/remote-access/mac/code-server.sh"

export MESH_WORKSTATION_DIR="$REPO_ROOT"
# shellcheck source=/dev/null
. "$DRIVER"

# shellcheck source=../lib/assert.sh
source "$SELF_DIR/../lib/assert.sh"

SANDBOX="$(mktemp -d -t code-server-user-data.XXXXXX)"
trap '[[ -d "$SANDBOX" ]] && rm -rf "$SANDBOX"' EXIT

make_fixture() {
    local h="$1"
    mkdir -p \
        "$h/.local/bin" \
        "$h/.config/code-server" \
        "$h/Library/LaunchAgents"

    cat > "$h/.local/bin/code-server" <<'SH'
#!/usr/bin/env bash
printf '4.118.0 test-build\n'
SH
    chmod +x "$h/.local/bin/code-server"

    cat > "$h/.config/code-server/config.yaml" <<'YAML'
bind-addr: 127.0.0.1:8080
auth: password
password: test-password
cert: false
YAML

    touch "$h/Library/LaunchAgents/com.tester.code-server.plist"
}

run_check() {
    local h="$1"
    (
        HOME="$h"
        USER="tester"
        export CODE_SERVER_LABEL="com.tester.code-server"
        check
    )
}

H="$SANDBOX/healthy"
make_fixture "$H"
mkdir -p "$H/.local/share/code-server/User/globalStorage"
chmod 0700 \
    "$H/.local/share/code-server" \
    "$H/.local/share/code-server/User" \
    "$H/.local/share/code-server/User/globalStorage"
ASSERT_MSG="healthy fixture passes with persistent code-server user data" \
    assert_true 'run_check "$H"'

H="$SANDBOX/missing-user-data"
make_fixture "$H"
ASSERT_MSG="missing ~/.local/share/code-server makes check fail" \
    assert_false 'run_check "$H"'

H="$SANDBOX/missing-user-subdir"
make_fixture "$H"
mkdir -p "$H/.local/share/code-server"
ASSERT_MSG="missing ~/.local/share/code-server/User makes check fail" \
    assert_false 'run_check "$H"'

H="$SANDBOX/missing-global-storage"
make_fixture "$H"
mkdir -p "$H/.local/share/code-server/User"
ASSERT_MSG="missing ~/.local/share/code-server/User/globalStorage makes check fail" \
    assert_false 'run_check "$H"'

H="$SANDBOX/global-storage-is-file"
make_fixture "$H"
mkdir -p "$H/.local/share/code-server/User"
printf 'not a directory\n' > "$H/.local/share/code-server/User/globalStorage"
ASSERT_MSG="non-directory ~/.local/share/code-server/User/globalStorage makes check fail" \
    assert_false 'run_check "$H"'

H="$SANDBOX/user-data-is-file"
make_fixture "$H"
mkdir -p "$H/.local/share"
printf 'not a directory\n' > "$H/.local/share/code-server"
ASSERT_MSG="non-directory ~/.local/share/code-server makes check fail" \
    assert_false 'run_check "$H"'

summary
